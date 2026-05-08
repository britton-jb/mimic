# Pure wall-time bench — no telemetry attached. Isolates the question:
# does pool_size > 1 actually reduce contention?
#
# Usage:
#   MIX_ENV=test MIMIC_POOL_SIZE=1  mix run --no-start bench/wall.exs
#   MIX_ENV=test MIMIC_POOL_SIZE=10 mix run --no-start bench/wall.exs

if pool = System.get_env("MIMIC_POOL_SIZE") do
  Application.put_env(:mimic, :pool_size, String.to_integer(pool))
end

{:ok, _} = Application.ensure_all_started(:mimic)

Code.require_file("../test/support/test_modules.ex", __DIR__)
Mimic.copy(Calculator)

defmodule WallBench do
  @moduledoc false
  alias Mimic.Server.Router

  def run(k, m) do
    parent = self()

    {us, _} =
      :timer.tc(fn ->
        for _ <- 1..k, do: spawn_link(fn -> worker(parent, m) end)
        for _ <- 1..k, do: receive(do: (:done -> :ok))
      end)

    per_call = us / (k * m)
    IO.puts("pool=#{Router.pool_size()} K=#{k} M=#{m} wall=#{Float.round(us / 1000, 2)}ms per_call=#{Float.round(per_call, 2)}us")
  end

  defp worker(parent, m) do
    Mimic.stub(Calculator, :add, fn x, y -> x + y end)
    for _ <- 1..m, do: Calculator.add(1, 2)
    send(parent, :done)
  end
end

# Warmup
WallBench.run(4, 500)

for k <- [1, 4, 16, 64, 256], _ <- 1..3, do: WallBench.run(k, 1_000)
