defmodule Mimic.Server do
  @moduledoc false

  alias Mimic.Server.Coordinator
  alias Mimic.Server.Router

  @long_timeout Application.compile_env(:mimic, :server_timeout, 60_000)

  @spec allow(module, pid, pid) :: {:ok, module} | {:error, :global}
  def allow(module, owner_pid, allowed_pid) do
    coord_call({:allow, module, owner_pid, allowed_pid}, 5000)
  end

  @spec verify(pid) :: non_neg_integer
  def verify(pid), do: Router.shard_call(pid, {:verify, pid}, @long_timeout)

  @spec verify_on_exit(pid) :: :ok
  def verify_on_exit(pid), do: Router.shard_call(pid, {:verify_on_exit, pid}, @long_timeout)

  @spec stub(module, atom, arity, function) ::
          {:ok, module} | {:error, :not_global_owner} | {:error, {:module_not_copied, module}}
  def stub(module, fn_name, arity, func) do
    setup_call(module, fn caller -> {:stub, caller, module, fn_name, arity, func} end)
  end

  @spec stub(module) ::
          {:ok, module} | {:error, :not_global_owner} | {:error, {:module_not_copied, module}}
  def stub(module) do
    setup_call(module, fn caller -> {:stub, caller, module} end)
  end

  @spec stub_with(module, module) ::
          {:ok, module} | {:error, :not_global_owner} | {:error, {:module_not_copied, module}}
  def stub_with(module, mocking_module) do
    setup_call(module, fn caller -> {:stub_with, caller, module, mocking_module} end)
  end

  @spec expect(module, atom, arity, non_neg_integer, function) ::
          {:ok, module} | {:error, :not_global_owner} | {:error, {:module_not_copied, module}}
  def expect(module, fn_name, arity, num_calls, func) do
    setup_call(module, fn caller ->
      {:expect, caller, {module, fn_name, func, arity}, num_calls}
    end)
  end

  @spec set_global_mode(pid) :: :ok
  def set_global_mode(owner_pid), do: coord_call({:set_global_mode, owner_pid})

  @spec set_private_mode :: :ok
  def set_private_mode, do: coord_call(:set_private_mode)

  @spec get_mode :: :private | :global
  def get_mode, do: coord_call(:get_mode)

  @spec exit(pid) :: :ok
  def exit(pid), do: Router.shard_cast(pid, {:exit, pid})

  @spec reset(module) :: :ok
  def reset(module), do: coord_call({:reset, module})

  @spec soft_reset(module) :: :ok
  def soft_reset(_module), do: coord_call(:soft_reset)

  @spec mark_to_copy(module, keyword) :: :ok | {:error, {:module_already_copied, module}}
  def mark_to_copy(module, opts), do: coord_call({:mark_to_copy, module, opts})

  @spec marked_to_copy?(module) :: boolean
  def marked_to_copy?(module), do: coord_call({:marked_to_copy?, module})

  @spec get_calls(module, atom, arity) :: {:ok, list(list(term))} | {:error, :not_found}
  def get_calls(module, fn_name, arity) do
    caller_pids = [self() | Process.get(:"$callers", [])]

    caller =
      case allowed_pid(caller_pids, module) do
        {:ok, owner_pid} -> owner_pid
        _ -> self()
      end

    with {:ok, _} <- ensure_module_copied(module) do
      Router.shard_call(caller, {:get_calls, caller, module, fn_name, arity}, 5000)
    end
  end

  def apply(module, fn_name, args) do
    arity = Enum.count(args)
    original_module = Mimic.Module.original(module)

    if function_exported?(original_module, fn_name, arity) do
      caller_pids = [self() | Process.get(:"$callers", [])]

      case allowed_pid(caller_pids, module) do
        {:ok, owner_pid} -> do_apply(owner_pid, module, fn_name, arity, args)
        _ -> apply_original(module, fn_name, args)
      end
    else
      raise Mimic.Error, module: module, fn_name: fn_name, arity: arity
    end
  end

  def allowed_pid(pids, module) do
    case :ets.lookup(Coordinator, :mode) do
      [{:mode, :private}] ->
        case :ets.select(Coordinator, match_spec(pids, module)) do
          [] -> :none
          [owner_pid | _] -> {:ok, owner_pid}
        end

      [{:mode, :global, global_pid}] ->
        case :ets.lookup(Coordinator, {global_pid, module}) do
          [] -> :none
          [{{^global_pid, ^module}, owner_pid}] -> {:ok, owner_pid}
        end
    end
  end

  defp setup_call(module, msg_fun) do
    caller = self()

    with :ok <- check_mode(caller),
         {:ok, _} <- ensure_module_copied(module) do
      Router.shard_call(caller, msg_fun.(caller), @long_timeout)
    end
  end

  defp ensure_module_copied(module) do
    :telemetry.span(
      [:mimic, :ensure_module_copied],
      %{module: module},
      fn -> do_ensure_module_copied(module) end
    )
  end

  defp do_ensure_module_copied(module) do
    if Mimic.Module.copied?(module) do
      {{:ok, :cached}, %{outcome: :cached}}
    else
      case coord_call({:ensure_module_copied, module}) do
        {:ok, outcome} -> {{:ok, outcome}, %{outcome: outcome}}
        {:error, _} = err -> {err, %{outcome: :error}}
      end
    end
  end

  defp check_mode(caller) do
    case :ets.lookup(Coordinator, :mode) do
      [{:mode, :private}] -> :ok
      [{:mode, :global, ^caller}] -> :ok
      [{:mode, :global, _}] -> {:error, :not_global_owner}
    end
  end

  defp coord_call(msg, timeout \\ @long_timeout), do: GenServer.call(Coordinator, msg, timeout)

  defp match_spec(pids, module) do
    guards = Enum.map(pids, fn pid -> {:==, :"$1", pid} end)
    orelse = List.to_tuple([:orelse | guards])
    [{{{:"$1", module}, :"$2"}, [orelse], [:"$2"]}]
  end

  defp do_apply(owner_pid, module, fn_name, arity, args) do
    metadata = %{module: module, fn_name: fn_name, arity: arity}

    :telemetry.span([:mimic, :apply], metadata, fn ->
      msg = {:apply, owner_pid, module, fn_name, arity, args}

      case Router.shard_call(owner_pid, msg, :infinity) do
        {:ok, func} ->
          {Kernel.apply(func, args), %{outcome: :mocked}}

        :original ->
          {apply_original(module, fn_name, args), %{outcome: :original}}

        {:unexpected, :fulfilled} ->
          mfa = Exception.format_mfa(module, fn_name, arity)

          raise Mimic.UnexpectedCallError,
                "#{mfa} called in process #{inspect(self())} but expectations are already fulfilled"

        {:unexpected, num_calls, num_applied_calls} ->
          mfa = Exception.format_mfa(module, fn_name, arity)

          raise Mimic.UnexpectedCallError,
                "expected #{mfa} to be called #{num_calls} time(s) " <>
                  "but it has been called #{num_applied_calls} time(s) in process #{inspect(self())}"
      end
    end)
  end

  defp apply_original(module, fn_name, args),
    do: Kernel.apply(Mimic.Module.original(module), fn_name, args)
end
