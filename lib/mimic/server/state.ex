defmodule Mimic.Server.State do
  @moduledoc false

  defstruct expectations: %{},
            stubs: %{},
            call_history: %{},
            verify_on_exit: MapSet.new()

  defmodule Expectation do
    @moduledoc false
    defstruct func: nil, num_applied_calls: 0, num_calls: nil
  end

  def find_stub(stubs, module, fn_name, arity, caller) do
    case get_in(stubs, [caller, {module, fn_name, arity}]) do
      func when is_function(func) -> {:ok, func}
      nil -> :unexpected
    end
  end

  def put_call_history(state, caller, module, fn_name, arity, args) do
    update_in(
      state,
      [
        Access.key(:call_history),
        Access.key(caller, %{}),
        Access.key({module, fn_name, arity}, [])
      ],
      &[args | &1]
    )
  end

  def apply_call_to_expectations([
        expectation = %Expectation{num_applied_calls: applied, num_calls: total} | rest
      ]) do
    next = applied + 1

    cond do
      next == total ->
        {:ok, expectation.func, rest}

      next < total ->
        {:ok, expectation.func, [%{expectation | num_applied_calls: next} | rest]}

      true ->
        {:unexpected, total, next}
    end
  end
end
