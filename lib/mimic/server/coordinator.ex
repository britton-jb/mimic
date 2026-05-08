defmodule Mimic.Server.Coordinator do
  @moduledoc false
  use GenServer
  alias Mimic.Cover
  alias Mimic.Server.State
  alias Mimic.Server.State.Expectation

  @long_timeout Application.compile_env(:mimic, :server_timeout, 60_000)

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    :ets.new(__MODULE__, [:named_table, :protected, :set])
    {:ok, do_set_private_mode(%State{})}
  end

  @impl true
  def handle_cast({:exit, pid}, state) do
    {:noreply, clear_data_from_pid(pid, state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_state =
      if MapSet.member?(state.verify_on_exit, pid) do
        state
      else
        clear_data_from_pid(pid, state)
      end

    {:noreply, new_state}
  end

  def handle_info({ref, :ok}, state) do
    {:noreply, %{state | reset_tasks: Map.delete(state.reset_tasks, ref)}}
  end

  def handle_info(msg, state) do
    IO.puts("handle_info with #{inspect(msg)} not handled")
    {:noreply, state}
  end

  @impl true
  def handle_call({:apply, owner_pid, module, fn_name, arity, args}, _from, state) do
    caller = if state.mode == :private, do: owner_pid, else: state.global_pid

    case get_in(state.expectations, [Access.key(caller, %{}), {module, fn_name, arity}]) do
      [_ | _] = expectations ->
        case State.apply_call_to_expectations(expectations) do
          {:ok, func, new_expectations} ->
            expectations =
              put_in(state.expectations, [caller, {module, fn_name, arity}], new_expectations)

            state = State.put_call_history(state, caller, module, fn_name, arity, args)

            {:reply, {:ok, func}, %{state | expectations: expectations}}

          {:unexpected, num_calls, num_applied_calls} ->
            {:reply, {:unexpected, num_calls, num_applied_calls}, state}
        end

      expectations ->
        case {State.find_stub(state.stubs, module, fn_name, arity, caller), expectations} do
          {{:ok, func}, _} ->
            state = State.put_call_history(state, caller, module, fn_name, arity, args)
            {:reply, {:ok, func}, state}

          {:unexpected, []} ->
            {:reply, {:unexpected, :fulfilled}, state}

          {:unexpected, nil} ->
            {:reply, :original, state}
        end
    end
  end

  def handle_call({:stub, module, fn_name, func, arity, owner}, _from, state) do
    with_registered_owner(module, owner, state, fn state ->
      func = maybe_typecheck_func(module, fn_name, func)

      {:reply, {:ok, module},
       %{
         state
         | stubs: put_in(state.stubs, [Access.key(owner, %{}), {module, fn_name, arity}], func)
       }}
    end)
  end

  def handle_call({:stub, module, owner}, _from, state) do
    with_registered_owner(module, owner, state, fn state ->
      stubs =
        Enum.reduce(public_functions(module), state.stubs, fn {fn_name, arity}, stubs ->
          func = stub_function(module, fn_name, arity)
          put_in(stubs, [Access.key(owner, %{}), {module, fn_name, arity}], func)
        end)

      {:reply, {:ok, module}, %{state | stubs: stubs}}
    end)
  end

  def handle_call({:stub_with, mocked_module, mocking_module, owner}, _from, state) do
    with_registered_owner(mocked_module, owner, state, fn state ->
      mocked = MapSet.new(public_functions(Mimic.Module.original(mocked_module)))
      mocking = MapSet.new(public_functions(mocking_module))

      to_mock = MapSet.intersection(mocking, mocked)
      to_stub = MapSet.difference(mocked, mocking)

      stubs =
        Enum.reduce(to_mock, state.stubs, fn {fn_name, arity}, stubs ->
          func = anonymize_module_function(mocking_module, fn_name, arity)
          func = maybe_typecheck_func(mocked_module, fn_name, func)
          put_in(stubs, [Access.key(owner, %{}), {mocked_module, fn_name, arity}], func)
        end)

      stubs =
        Enum.reduce(to_stub, stubs, fn {fn_name, arity}, stubs ->
          func = stub_function(mocked_module, fn_name, arity)
          put_in(stubs, [Access.key(owner, %{}), {mocked_module, fn_name, arity}], func)
        end)

      {:reply, {:ok, mocked_module}, %{state | stubs: stubs}}
    end)
  end

  def handle_call({:expect, {module, fn_name, func, arity}, num_calls, owner}, _from, state) do
    with_registered_owner(module, owner, state, fn state ->
      func = maybe_typecheck_func(module, fn_name, func)
      expectation = %Expectation{func: func, num_calls: num_calls}

      expectations =
        update_in(
          state.expectations,
          [Access.key(owner, %{}), {module, fn_name, arity}],
          &((&1 || []) ++ [expectation])
        )

      {:reply, {:ok, module}, %{state | expectations: expectations}}
    end)
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

  def handle_call({:allow, module, owner_pid, allowed_pid}, _from, %State{mode: :private} = state) do
    case :ets.lookup(__MODULE__, {owner_pid, module}) do
      [{{^owner_pid, ^module}, actual_owner_pid}] ->
        :ets.insert(__MODULE__, {{allowed_pid, module}, actual_owner_pid})

      [] ->
        :ets.insert(__MODULE__, {{allowed_pid, module}, owner_pid})
    end

    {:reply, {:ok, module}, state}
  end

  def handle_call({:allow, _, _, _}, _from, %State{mode: :global} = state) do
    {:reply, {:error, :global}, state}
  end

  def handle_call({:verify, pid}, _from, state) do
    expectations = state.expectations[pid] || %{}

    pending =
      for {{module, fn_name, arity}, mfa_expectations} <- expectations,
          %Expectation{num_applied_calls: applied, num_calls: total} <- mfa_expectations,
          total != applied do
        {{module, fn_name, arity}, total, applied}
      end

    {:reply, pending, state}
  end

  def handle_call({:verify_on_exit, pid}, _from, state) do
    {:reply, :ok, %{state | verify_on_exit: MapSet.put(state.verify_on_exit, pid)}}
  end

  def handle_call({:soft_reset, _module}, _from, state) do
    {:reply, :ok, %{state | expectations: %{}, stubs: %{}, mode: :private, global_pid: nil}}
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
    {:reply, marked_to_copy?(module, state), state}
  end

  def handle_call({:mark_to_copy, module, opts}, _from, state) do
    if marked_to_copy?(module, state) do
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

  def handle_call({:get_calls, {module, fn_name, arity}, owner_pid}, _from, state) do
    caller_pids = [self() | Process.get(:"$callers", [])]

    caller_pid =
      case Mimic.Server.allowed_pid(caller_pids, module) do
        {:ok, pid} -> pid
        _ -> owner_pid
      end

    case ensure_module_copied(module, state) do
      {:ok, state} ->
        case pop_in(state.call_history, [Access.key(caller_pid, %{}), {module, fn_name, arity}]) do
          {calls, call_history} when is_list(calls) ->
            {:reply, {:ok, Enum.reverse(calls)}, %{state | call_history: call_history}}

          {nil, _} ->
            {:reply, {:ok, []}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp with_registered_owner(module, owner, state, fun) do
    with {:ok, state} <- ensure_module_copied(module, state),
         true <- valid_mode?(state, owner) do
      monitor_if_not_verify_on_exit(owner, state.verify_on_exit)
      :ets.insert_new(__MODULE__, {{owner, module}, owner})
      fun.(state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      false -> {:reply, {:error, :not_global_owner}, state}
    end
  end

  defp clear_data_from_pid(pid, state) do
    select = [{{{pid, :_}}, [], [true]}, {{{:_, :_}, pid}, [], [true]}]
    :ets.select_delete(__MODULE__, select)

    state =
      if pid == state.global_pid do
        do_set_private_mode(state)
      else
        state
      end

    %{
      state
      | expectations: Map.delete(state.expectations, pid),
        stubs: Map.delete(state.stubs, pid),
        call_history: Map.delete(state.call_history, pid)
    }
  end

  defp public_functions(module) do
    internal = [__info__: 1, module_info: 0, module_info: 1]
    Enum.filter(module.module_info(:exports), &(&1 not in internal))
  end

  defp maybe_typecheck_func(module, fn_name, func) do
    case module.__mimic_info__() do
      {:ok, %{type_check: true}} -> Mimic.TypeCheck.wrap(module, fn_name, func)
      _ -> func
    end
  end

  defp marked_to_copy?(module, state) do
    MapSet.member?(state.modules_to_be_copied, module)
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

  defp valid_mode?(state, caller) do
    state.mode == :private or (state.mode == :global and state.global_pid == caller)
  end

  defp monitor_if_not_verify_on_exit(pid, verify_on_exit) do
    unless MapSet.member?(verify_on_exit, pid) do
      Process.monitor(pid)
    end
  end

  defp stub_function(module, fn_name, arity) do
    args = stub_args(arity)

    clause =
      quote do
        unquote_splicing(args) ->
          mfa = Exception.format_mfa(unquote(module), unquote(fn_name), unquote(args))

          raise Mimic.UnexpectedCallError,
                "Stub! Unexpected call to #{mfa} from #{inspect(self())}"
      end

    {fun, _} = Code.eval_quoted({:fn, [], clause})
    fun
  end

  defp anonymize_module_function(module, fn_name, arity) do
    args = stub_args(arity)

    clause =
      quote do
        unquote_splicing(args) ->
          apply(unquote(module), unquote(fn_name), [unquote_splicing(args)])
      end

    {fun, _} = Code.eval_quoted({:fn, [], clause})
    fun
  end

  defp stub_args(arity) do
    Enum.map(1..arity//1, fn i -> Macro.var(:"arg_#{i}", nil) end)
  end

  defp do_set_global_mode(owner_pid, state) do
    :ets.insert(__MODULE__, {:mode, :global, owner_pid})
    %{state | global_pid: owner_pid, mode: :global}
  end

  defp do_set_private_mode(state) do
    :ets.insert(__MODULE__, {:mode, :private})
    %{state | global_pid: nil, mode: :private}
  end
end
