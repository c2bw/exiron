defmodule Exiron.Metrics do
  @moduledoc false
  use GenServer

  # Fixed global histograms. Per-hook counters/gauges come from the current Hub
  # snapshot, so removed hook names cannot accumulate in this collector.
  @buckets [0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2.5, 5, 10, 30, 60]
  @send_kinds [:respond, :push, :unavailable, :overloaded]
  @outcomes [:ok, :error, :partial_error, :timeout]
  @events [[:exiron, :hub, :response, :stop], [:exiron, :hub, :send, :stop]]

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.get(opts, :table, __MODULE__)

    :ets.new(table, [:named_table, :public, :set, write_concurrency: true, read_concurrency: true])

    keys = [
      :response | for(kind <- @send_kinds, outcome <- @outcomes, do: {:send, kind, outcome})
    ]

    for key <- keys, do: :ets.insert(table, row(key))
    handler = {__MODULE__, table}
    :telemetry.detach(handler)
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.handle_event/4, table)
    {:ok, %{handler: handler}}
  end

  @impl true
  def terminate(_reason, state), do: :telemetry.detach(state.handler)

  def handle_event([:exiron, :hub, :response, :stop], %{duration: duration}, _metadata, table),
    do: observe(table, :response, duration)

  def handle_event(
        [:exiron, :hub, :send, :stop],
        %{duration: duration},
        %{kind: kind, outcome: outcome},
        table
      )
      when kind in @send_kinds and outcome in @outcomes,
      do: observe(table, {:send, kind, outcome}, duration)

  def handle_event(_event, _measurements, _metadata, _table), do: :ok

  defp observe(table, key, duration) when is_integer(duration) and duration >= 0 do
    microseconds = System.convert_time_unit(duration, :native, :microsecond)
    index = Enum.find_index(@buckets, &(microseconds <= &1 * 1_000_000)) || length(@buckets)
    :ets.update_counter(table, key, [{2, 1}, {3, microseconds}, {4 + index, 1}])
    :ok
  rescue
    # A telemetry event can race collector shutdown/restart. It must not detach
    # the handler or fail the domain operation that emitted it.
    ArgumentError -> :ok
  end

  defp observe(_table, _key, _duration), do: :ok
  defp row(key), do: List.to_tuple([key, 0, 0 | List.duplicate(0, length(@buckets) + 1)])

  def scrape do
    snapshot =
      try do
        Exiron.Hub.metrics_snapshot()
      catch
        :exit, _ -> nil
      end

    render(snapshot)
  end

  def render(snapshot, table \\ __MODULE__) do
    rows =
      try do
        :ets.tab2list(table)
      rescue
        ArgumentError -> []
      end

    [
      gauge(
        "exiron_metrics_collector_up",
        "Histogram collector available.",
        if(rows == [], do: 0, else: 1)
      ),
      gauge(
        "exiron_hub_snapshot_available",
        "Hub answered the metrics snapshot request.",
        if(snapshot, do: 1, else: 0)
      ),
      gauge("exiron_vm_memory_bytes", "Total BEAM memory in bytes.", :erlang.memory(:total)),
      gauge(
        "exiron_vm_run_queue",
        "Runnable BEAM processes and ports.",
        :erlang.statistics(:run_queue)
      ),
      hub_metrics(snapshot),
      histogram(
        "exiron_response_duration_seconds",
        "Successful response latency from acceptance through Telegram send completion.",
        rows,
        :response
      ),
      histogram(
        "exiron_send_duration_seconds",
        "Telegram send operation duration; timeouts have unknown delivery outcome.",
        rows,
        :send
      )
    ]
    |> IO.iodata_to_binary()
  end

  defp hub_metrics(nil), do: []

  defp hub_metrics(snapshot) do
    [
      gauge("exiron_hub_enabled", "Hub enabled.", if(snapshot.enabled, do: 1, else: 0)),
      gauge(
        "exiron_pending_requests",
        "Accepted requests awaiting completion or expiry.",
        snapshot.pending
      ),
      gauge(
        "exiron_pending_limit",
        "Configured global pending request limit.",
        snapshot.pending_limit
      ),
      buffer_metrics(snapshot.buffer_capacity),
      send_byte_metrics(snapshot),
      suppression_metrics(snapshot.telegram_suppression),
      gauge("exiron_in_flight_sends", "Running Telegram send operations.", snapshot.sends),
      gauge(
        "exiron_in_flight_sends_limit",
        "Configured global send operation limit.",
        snapshot.sends_limit
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_in_flight_sends",
        "gauge",
        "Active send operations, including coordinator and cooldown waits.",
        & &1.health.in_flight_sends
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_in_flight_sends_limit",
        "gauge",
        "Effective per-hook send operation limit.",
        & &1.health.in_flight_send_limit
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_send_capacity_rejections_total",
        "counter",
        "Send operations rejected before starting by global or per-hook capacity; resets with Hub state.",
        & &1.health.send_capacity_rejections
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_available",
        "gauge",
        "Hook available for new requests.",
        &if(&1.connected, do: 1, else: 0)
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_queued_messages",
        "gauge",
        "Messages in the outbound queue.",
        & &1.health.queued
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_queued_bytes",
        "gauge",
        "Payload bytes in the outbound queue, excluding unacknowledged deliveries.",
        & &1.health.queued_bytes
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_buffered_bytes",
        "gauge",
        "Queued plus unacknowledged delivery payload bytes.",
        & &1.buffered_bytes
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_buffered_bytes_limit",
        "gauge",
        "Configured per-hook payload byte limit.",
        & &1.buffered_bytes_limit
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_pending_requests",
        "gauge",
        "Accepted requests assigned to the hook.",
        & &1.health.pending
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_unavailable_rejections_total",
        "counter",
        "Requests rejected because a hook was unavailable; resets with Hub state.",
        & &1.health.unavailable_rejections
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_overload_rejections_total",
        "counter",
        "Requests rejected by admission limits; resets with Hub state.",
        & &1.health.overload_rejections
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_send_failures_total",
        "counter",
        "Failed send operations including start failures; resets with Hub state.",
        & &1.health.send_failures
      )
    ]
  end

  defp suppression_metrics(summary) do
    [
      gauge(
        "exiron_telegram_suppression_available",
        "Telegram rejection cache snapshot available.",
        if(summary.available, do: 1, else: 0)
      ),
      gauge(
        "exiron_telegram_suppressions",
        "Token or token/chat rejection cooldowns currently active.",
        summary.active
      ),
      header(
        "exiron_telegram_suppressed_attempts_total",
        "counter",
        "Send attempts skipped after definitive rejection; resets with coordinator."
      ),
      "exiron_telegram_suppressed_attempts_total #{summary.suppressed_attempts}\n",
      header(
        "exiron_telegram_rejection_probes_total",
        "counter",
        "Send attempts admitted after rejection cooldown expiry; resets with coordinator."
      ),
      "exiron_telegram_rejection_probes_total #{summary.probes}\n",
      header(
        "exiron_telegram_recoveries_total",
        "counter",
        "Expired rejection records cleared by a confirmed successful send; resets with coordinator."
      ),
      "exiron_telegram_recoveries_total #{summary.recoveries}\n"
    ]
  end

  defp send_byte_metrics(snapshot) do
    [
      gauge(
        "exiron_in_flight_send_bytes",
        "Source payload and option bytes retained by active send operations, including coordinator waits.",
        snapshot.send_capacity.bytes
      ),
      gauge(
        "exiron_in_flight_send_bytes_limit",
        "Global active send payload byte budget.",
        snapshot.send_capacity.limit
      ),
      header(
        "exiron_send_byte_capacity_rejections_total",
        "counter",
        "Send admissions rejected with byte capacity exhausted; resets with Hub state."
      ),
      "exiron_send_byte_capacity_rejections_total #{snapshot.send_capacity.rejections}\n",
      hook_metric(
        snapshot.hooks,
        "exiron_hook_in_flight_send_bytes",
        "gauge",
        "Active send payload and option bytes for the hook.",
        & &1.health.in_flight_send_bytes
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_in_flight_send_bytes_limit",
        "gauge",
        "Effective per-hook active send byte budget.",
        & &1.health.in_flight_send_bytes_limit
      ),
      hook_metric(
        snapshot.hooks,
        "exiron_hook_send_byte_capacity_rejections_total",
        "counter",
        "Hook send admissions rejected with byte capacity exhausted; resets with Hub state.",
        & &1.health.send_byte_capacity_rejections
      )
    ]
  end

  defp buffer_metrics(capacity) do
    [
      gauge(
        "exiron_buffered_bytes",
        "Encoded payload bytes in all queues and unacknowledged deliveries.",
        capacity.bytes
      ),
      gauge(
        "exiron_buffered_bytes_limit",
        "Global encoded buffered-payload budget.",
        capacity.limit
      ),
      gauge(
        "exiron_buffered_awaiting_ack_bytes",
        "Encoded bytes in unacknowledged HTTP and WebSocket batches.",
        capacity.awaiting_ack_bytes
      ),
      header(
        "exiron_buffer_request_rejections_total",
        "counter",
        "Requests rejected by the global byte budget; resets with Hub state."
      ),
      "exiron_buffer_request_rejections_total #{capacity.request_rejections}\n",
      header(
        "exiron_buffer_listener_rejections_total",
        "counter",
        "Listener copies rejected by the global byte budget; resets with Hub state."
      ),
      "exiron_buffer_listener_rejections_total #{capacity.listener_rejections}\n"
    ]
  end

  defp gauge(name, help, value),
    do: [header(name, "gauge", help), name, " ", to_string(value), "\n"]

  defp hook_metric(hooks, name, type, help, value) do
    [
      header(name, type, help),
      Enum.map(hooks, fn hook ->
        sample(name, [{"hook", hook.name}], value.(hook))
      end)
    ]
  end

  defp histogram(name, help, rows, category) do
    selected =
      Enum.filter(rows, fn row ->
        key = elem(row, 0)
        key == category or (is_tuple(key) and elem(key, 0) == category)
      end)
      |> Enum.sort()

    [
      header(name, "histogram", help),
      Enum.map(selected, fn row ->
        labels =
          case elem(row, 0) do
            :response ->
              []

            {:send, kind, outcome} ->
              [{"kind", Atom.to_string(kind)}, {"outcome", Atom.to_string(outcome)}]
          end

        {buckets, _} =
          Enum.map_reduce(Enum.with_index(@buckets ++ ["+Inf"]), 0, fn {bound, i}, count ->
            count = count + elem(row, 3 + i)
            {sample(name <> "_bucket", labels ++ [{"le", to_string(bound)}], count), count}
          end)

        [
          buckets,
          sample(name <> "_sum", labels, elem(row, 2) / 1_000_000),
          sample(name <> "_count", labels, elem(row, 1))
        ]
      end)
    ]
  end

  defp header(name, type, help),
    do: ["# HELP ", name, " ", help, "\n# TYPE ", name, " ", type, "\n"]

  defp sample(name, [], value), do: [name, " ", to_string(value), "\n"]

  defp sample(name, labels, value) do
    labels =
      Enum.map_intersperse(labels, ",", fn {key, value} -> [key, "=\"", escape(value), "\""] end)

    [name, "{", labels, "} ", to_string(value), "\n"]
  end

  defp escape(value),
    do:
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\"", "\\\"")
end
