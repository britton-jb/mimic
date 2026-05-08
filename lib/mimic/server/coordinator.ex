defmodule Mimic.Server.Coordinator do
  @moduledoc false
  use GenServer
  alias Mimic.Cover
  alias Mimic.Server.Router

  defmodule CoordState do
    @moduledoc false
    defstruct mode: :private,
              global_pid: nil,
              modules_beam: %{},
              modules_to_be_copied: MapSet.new(),
              reset_tasks: %{},
              modules_opts: %{}
  end

  @long_timeout Application.compile_env(:mimic, :server_timeout, 60_000)

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    :ets.new(__MODULE__, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, do_set_private_mode(%CoordState{})}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if pid == state.global_pid do
      {:noreply, do_set_private_mode(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, :ok}, state) do
    {:noreply, %{state | reset_tasks: Map.delete(state.reset_tasks, ref)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:ensure_module_copied, module}, _from, state) do
    case ensure_module_copied(module, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_global_mode, owner_pid}, _from, state) do
    {:reply, :ok, do_set_global_mode(owner_pid, state)}
  end

  def handle_call(:set_private_mode, _from, state) do
    {:reply, :ok, do_set_private_mode(state)}
  end

  def handle_call(:get_mode, _from, state) do
    {:reply, state.mode, state}
  end

  def handle_call(
        {:allow, module, owner_pid, allowed_pid},
        _from,
        %CoordState{mode: :private} = state
      ) do
    case :ets.lookup(__MODULE__, {owner_pid, module}) do
      [{{^owner_pid, ^module}, actual_owner_pid}] ->
        :ets.insert(__MODULE__, {{allowed_pid, module}, actual_owner_pid})

      [] ->
        :ets.insert(__MODULE__, {{allowed_pid, module}, owner_pid})
    end

    {:reply, {:ok, module}, state}
  end

  def handle_call({:allow, _, _, _}, _from, %CoordState{mode: :global} = state) do
    {:reply, {:error, :global}, state}
  end

  def handle_call(:soft_reset, _from, state) do
    Router.broadcast_to_shards(:soft_reset)
    {:reply, :ok, %{state | mode: :private, global_pid: nil}}
  end

  def handle_call({:reset, module}, _from, state) do
    state = %{state | modules_to_be_copied: MapSet.delete(state.modules_to_be_copied, module)}

    tasks =
      if Mimic.Module.copied?(module) do
        task = Task.async(fn -> do_reset(module, state) end)
        Map.put(state.reset_tasks, task.ref, task)
      else
        state.reset_tasks
      end

    state = %{state | modules_beam: Map.delete(state.modules_beam, module)}

    if state.modules_to_be_copied == MapSet.new() do
      tasks |> Map.values() |> Task.await_many(@long_timeout)
      {:reply, :ok, %{state | reset_tasks: %{}}}
    else
      {:reply, :ok, %{state | reset_tasks: tasks}}
    end
  end

  def handle_call({:marked_to_copy?, module}, _from, state) do
    {:reply, MapSet.member?(state.modules_to_be_copied, module), state}
  end

  def handle_call({:mark_to_copy, module, opts}, _from, state) do
    if MapSet.member?(state.modules_to_be_copied, module) do
      {:reply, {:error, {:module_already_copied, module}}, state}
    else
      state = %{
        state
        | modules_to_be_copied: MapSet.put(state.modules_to_be_copied, module),
          modules_opts: Map.put(state.modules_opts, module, opts)
      }

      state =
        if Cover.enabled_for?(module) do
          {:ok, state} = ensure_module_copied(module, state)
          state
        else
          state
        end

      {:reply, :ok, state}
    end
  end

  defp do_reset(module, state) do
    case state.modules_beam[module] do
      {beam, coverdata} -> Cover.clear_module_and_import_coverdata!(module, beam, coverdata)
      _ -> Mimic.Module.clear!(module)
    end
  end

  defp ensure_module_copied(module, state) do
    cond do
      Mimic.Module.copied?(module) ->
        {:ok, state}

      MapSet.member?(state.modules_to_be_copied, module) ->
        case Mimic.Module.replace!(module, state.modules_opts[module]) do
          {beam_file, coverdata_path} ->
            modules_beam = Map.put(state.modules_beam, module, {beam_file, coverdata_path})
            {:ok, %{state | modules_beam: modules_beam}}

          :ok ->
            {:ok, state}
        end

      true ->
        {:error, {:module_not_copied, module}}
    end
  end

  defp do_set_global_mode(owner_pid, state) do
    Process.monitor(owner_pid)
    :ets.insert(__MODULE__, {:mode, :global, owner_pid})
    %{state | global_pid: owner_pid, mode: :global}
  end

  defp do_set_private_mode(state) do
    :ets.insert(__MODULE__, {:mode, :private})
    %{state | global_pid: nil, mode: :private}
  end
end
