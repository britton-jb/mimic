defmodule Mimic.Server.Shard do
  @moduledoc false
  use GenServer

  alias Mimic.Server.Coordinator
  alias Mimic.Server.Router
  alias Mimic.Server.State
  alias Mimic.Server.State.Expectation

  def child_spec(index) do
    name = Router.shard_name(index)
    %{id: name, start: {__MODULE__, :start_link, [name]}}
  end

  def start_link(name) do
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @impl true
  def init([]), do: {:ok, %State{}}

  @impl true
  def handle_cast({:exit, pid}, state) do
    {:noreply, clear_pid(pid, state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if MapSet.member?(state.verify_on_exit, pid) do
      {:noreply, state}
    else
      {:noreply, clear_pid(pid, state)}
    end
  end

  def handle_info(msg, state) do
    require Logger
    Logger.debug("Mimic.Server.Shard: unhandled #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:apply, caller, module, fn_name, arity, args}, _from, state) do
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

  def handle_call({:stub, caller, module, fn_name, arity, func}, _from, state) do
    register_owner(caller, module, state)
    func = maybe_typecheck_func(module, fn_name, func)

    {:reply, {:ok, module},
     %{
       state
       | stubs: put_in(state.stubs, [Access.key(caller, %{}), {module, fn_name, arity}], func)
     }}
  end

  def handle_call({:stub, caller, module}, _from, state) do
    register_owner(caller, module, state)

    stubs =
      Enum.reduce(public_functions(module), state.stubs, fn {fn_name, arity}, stubs ->
        func = stub_function(module, fn_name, arity)
        put_in(stubs, [Access.key(caller, %{}), {module, fn_name, arity}], func)
      end)

    {:reply, {:ok, module}, %{state | stubs: stubs}}
  end

  def handle_call({:stub_with, caller, mocked_module, mocking_module}, _from, state) do
    register_owner(caller, mocked_module, state)

    mocked = MapSet.new(public_functions(Mimic.Module.original(mocked_module)))
    mocking = MapSet.new(public_functions(mocking_module))

    to_mock = MapSet.intersection(mocking, mocked)
    to_stub = MapSet.difference(mocked, mocking)

    stubs =
      Enum.reduce(to_mock, state.stubs, fn {fn_name, arity}, stubs ->
        func = anonymize_module_function(mocking_module, fn_name, arity)
        func = maybe_typecheck_func(mocked_module, fn_name, func)
        put_in(stubs, [Access.key(caller, %{}), {mocked_module, fn_name, arity}], func)
      end)

    stubs =
      Enum.reduce(to_stub, stubs, fn {fn_name, arity}, stubs ->
        func = stub_function(mocked_module, fn_name, arity)
        put_in(stubs, [Access.key(caller, %{}), {mocked_module, fn_name, arity}], func)
      end)

    {:reply, {:ok, mocked_module}, %{state | stubs: stubs}}
  end

  def handle_call({:expect, caller, {module, fn_name, func, arity}, num_calls}, _from, state) do
    register_owner(caller, module, state)
    func = maybe_typecheck_func(module, fn_name, func)
    expectation = %Expectation{func: func, num_calls: num_calls}

    expectations =
      update_in(
        state.expectations,
        [Access.key(caller, %{}), {module, fn_name, arity}],
        &((&1 || []) ++ [expectation])
      )

    {:reply, {:ok, module}, %{state | expectations: expectations}}
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

  def handle_call(:soft_reset, _from, _state) do
    {:reply, :ok, %State{}}
  end

  def handle_call({:get_calls, caller_pid, module, fn_name, arity}, _from, state) do
    case pop_in(state.call_history, [Access.key(caller_pid, %{}), {module, fn_name, arity}]) do
      {calls, call_history} when is_list(calls) ->
        {:reply, {:ok, Enum.reverse(calls)}, %{state | call_history: call_history}}

      {nil, _} ->
        {:reply, {:ok, []}, state}
    end
  end

  defp register_owner(caller, module, state) do
    monitor_if_not_verify_on_exit(caller, state.verify_on_exit)
    :ets.insert_new(Coordinator, {{caller, module}, caller})
  end

  defp monitor_if_not_verify_on_exit(pid, verify_on_exit) do
    unless MapSet.member?(verify_on_exit, pid) do
      Process.monitor(pid)
    end
  end

  defp clear_pid(pid, state) do
    select = [{{{pid, :_}}, [], [true]}, {{{:_, :_}, pid}, [], [true]}]
    :ets.select_delete(Coordinator, select)

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
end
