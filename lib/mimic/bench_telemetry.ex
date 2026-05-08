defmodule Mimic.BenchTelemetry do
  @moduledoc """
  Suite-wide telemetry collector for Mimic. Aggregates `[:mimic, :apply, :stop]`
  and `[:mimic, :ensure_module_copied, :stop]` durations into ETS during the
  test run, then prints a summary.

  Wire it into a project's `test/test_helper.exs` before `ExUnit.start`:

      Mimic.BenchTelemetry.attach()
      ExUnit.after_suite(fn _ -> Mimic.BenchTelemetry.report() end)
      ExUnit.start()

  Optionally set `MIMIC_POOL_SIZE` to override the shard pool size before the
  Mimic application starts.
  """

  alias Mimic.Server.Router

  @table :mimic_bench_telemetry

  @spec attach() :: :ok
  def attach do
    :ets.new(@table, [:public, :named_table, :duplicate_bag, write_concurrency: true])

    :telemetry.attach_many(
      __MODULE__,
      [[:mimic, :apply, :stop], [:mimic, :ensure_module_copied, :stop]],
      &__MODULE__.handle/4,
      nil
    )

    :ok
  end

  @spec report() :: :ok
  def report do
    rows = :ets.tab2list(@table)
    applies = for {:apply, _outcome, d} <- rows, do: d
    ensures_cached = for {:ensure, :cached, d} <- rows, do: d
    ensures_already = for {:ensure, :already_copied, d} <- rows, do: d
    ensures_replaced = for {:ensure, :replaced, d} <- rows, do: d
    ensures_error = for {:ensure, :error, d} <- rows, do: d

    IO.puts("\n=== Mimic.BenchTelemetry pool=#{Router.pool_size()} ===")
    summarize("apply           ", applies)
    summarize("ensure:cached   ", ensures_cached)
    summarize("ensure:already  ", ensures_already)
    summarize("ensure:replaced ", ensures_replaced)
    summarize("ensure:error    ", ensures_error)

    coord_misses = ensures_already ++ ensures_replaced ++ ensures_error
    cached_count = length(ensures_cached)
    miss_count = length(coord_misses)

    if cached_count + miss_count > 0 do
      hit_rate = Float.round(cached_count / (cached_count + miss_count) * 100, 2)
      IO.puts("cache hit rate: #{cached_count}/#{cached_count + miss_count} (#{hit_rate}%)")
    end

    if cached_count > 0 and miss_count > 0 do
      miss_mean = div(Enum.sum(coord_misses), miss_count)
      estimated_saved_us = cached_count * miss_mean
      IO.puts("estimated coord time saved: #{ms(estimated_saved_us)}ms")
    end

    :ok
  end

  def handle([:mimic, :apply, :stop], %{duration: d}, %{outcome: outcome}, _),
    do: :ets.insert(@table, {:apply, outcome, d})

  def handle([:mimic, :ensure_module_copied, :stop], %{duration: d}, %{outcome: outcome}, _),
    do: :ets.insert(@table, {:ensure, outcome, d})

  defp summarize(_label, []), do: :ok

  defp summarize(label, durations) do
    sorted = Enum.sort(durations)
    n = length(sorted)
    sum = Enum.sum(sorted)
    mean = div(sum, n)

    pct = fn p -> Enum.at(sorted, min(n - 1, floor(n * p))) end

    IO.puts(
      "#{label}: n=#{n} total=#{ms(sum)}ms mean=#{us(mean)}us " <>
        "p50=#{us(pct.(0.50))}us p95=#{us(pct.(0.95))}us " <>
        "p99=#{us(pct.(0.99))}us max=#{us(List.last(sorted))}us"
    )
  end

  defp us(d), do: Float.round(d / 1000, 2)
  defp ms(d), do: Float.round(d / 1_000_000, 2)
end
