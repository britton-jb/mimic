# Mimic shard-pool contention benchmark.
#
# Usage (--no-start is required so Application.put_env applies before init):
#   MIX_ENV=test mix run --no-start bench/contention.exs
#   MIX_ENV=test MIMIC_POOL_SIZE=1 mix run --no-start bench/contention.exs
#
# Spawns K caller processes that each issue M mocked calls and reports
# p50/p95/p99 latency for [:mimic, :apply, :stop] plus per-call coordinator
# round-trip cost via [:mimic, :ensure_module_copied, :stop].

if pool = System.get_env("MIMIC_POOL_SIZE") do
  Application.put_env(:mimic, :pool_size, String.to_integer(pool))
end

{:ok, _} = Application.ensure_all_started(:mimic)

Code.require_file("../test/support/test_modules.ex", __DIR__)
Mimic.copy(Calculator)

defmodule Bench do
  @moduledoc false

  alias Mimic.Server.Router

  @samples :mimic_bench_samples

  def run(k_callers, m_calls) do
    :ets.new(@samples, [:public, :named_table, :duplicate_bag, write_concurrency: true])

    :telemetry.attach_many(
      {:bench, self()},
      [[:mimic, :apply, :stop], [:mimic, :ensure_module_copied, :stop]],
      &__MODULE__.handle/4,
      nil
    )

    parent = self()

    {wall_us, _} =
      :timer.tc(fn ->
        for _ <- 1..k_callers, do: spawn_link(fn -> worker(parent, m_calls) end)
        for _ <- 1..k_callers, do: receive(do: (:done -> :ok))
      end)

    :telemetry.detach({:bench, self()})

    rows = :ets.tab2list(@samples)
    :ets.delete(@samples)

    applies = for {:apply, d} <- rows, do: d
    ensures = for {:ensure_module_copied, d} <- rows, do: d

    print(k_callers, m_calls, wall_us, applies, ensures)
  end

  def handle([:mimic, kind, :stop], %{duration: d}, _meta, _),
    do: :ets.insert(@samples, {kind, d})

  defp worker(parent, m_calls) do
    Mimic.stub(Calculator, :add, fn x, y -> x + y end)
    for _ <- 1..m_calls, do: Calculator.add(1, 2)
    send(parent, :done)
  end

  defp print(k, m, wall_us, applies, ensures) do
    IO.puts("=== K=#{k} M=#{m} pool=#{Router.pool_size()} ===")
    IO.puts("wall: #{Float.round(wall_us / 1000, 2)} ms")

    summarize("apply", applies)
    summarize("ensure", ensures)

    apply_total = Enum.sum(applies)
    ensure_total = Enum.sum(ensures)

    if apply_total > 0 do
      pct = Float.round(ensure_total / apply_total * 100, 2)
      IO.puts("ensure_total / apply_total: #{pct}%")
    end

    IO.puts("")
  end

  defp summarize(_label, []), do: :ok

  defp summarize(label, durations) do
    sorted = Enum.sort(durations)
    n = length(sorted)

    pct = fn p ->
      idx = max(0, min(n - 1, floor(n * p)))
      Enum.at(sorted, idx)
    end

    mean = div(Enum.sum(sorted), n)

    IO.puts(
      "#{label}: n=#{n} mean=#{ns(mean)}us p50=#{ns(pct.(0.50))}us " <>
        "p95=#{ns(pct.(0.95))}us p99=#{ns(pct.(0.99))}us max=#{ns(List.last(sorted))}us"
    )
  end

  defp ns(d), do: Float.round(d / 1000, 2)
end

# Warmup
Bench.run(4, 1_000)

for k <- [1, 4, 16, 64, 256] do
  Bench.run(k, 1_000)
end
