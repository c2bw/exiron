defmodule ExironWeb.Plugs.RateLimit.Cleaner do
  @moduledoc """
  Creates the rate limit ETS table and periodically prunes stale counter buckets.

  ## Options

    * `:table` - ETS table name (default: `:rate_limit_entries`)
    * `:interval` - cleanup interval in milliseconds (default: 60_000)
    * `:window_seconds` - second buckets older than this are pruned (default: 60)

  """

  use GenServer

  @defaults [table: :rate_limit_entries, interval: 60_000, window_seconds: 60]

  def start_link(opts) do
    opts = Keyword.merge(@defaults, opts)
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def cleanup(table, window_seconds) do
    oldest_active_bucket = System.system_time(:second) - window_seconds + 1

    :ets.select_delete(table, [
      {{{:_, :_, :"$1"}, :_}, [{:<, :"$1", oldest_active_bucket}], [true]},
      {{{:_, :"$1"}, :_}, [{:<, :"$1", oldest_active_bucket}], [true]}
    ])
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    interval = Keyword.fetch!(opts, :interval)

    ensure_table(table)
    schedule_cleanup(interval)

    {:ok,
     %{table: table, interval: interval, window_seconds: Keyword.fetch!(opts, :window_seconds)}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup(state.table, state.window_seconds)
    schedule_cleanup(state.interval)
    {:noreply, state}
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp ensure_table(table) do
    case :ets.info(table) do
      :undefined ->
        :ets.new(table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      _info ->
        table
    end
  end
end
