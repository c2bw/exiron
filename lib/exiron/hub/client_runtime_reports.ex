defmodule Exiron.Hub.ClientRuntimeReports do
  @moduledoc false
  alias Exiron.Hub.Transition
  @stale_ms 15_000
  @phases ~w(idle connecting polling handling waiting backing_off draining stopped)
  @gauges ~w(active_handlers overdue_handlers quarantined_messages quarantine_bytes)
  @keys ~w(client_id runtime_ref sequence phase active_handlers overdue_handlers quarantined_messages quarantine_bytes quarantine_enabled quarantine_available)
  @fields %{
    "phase" => :phase,
    "active_handlers" => :active_handlers,
    "overdue_handlers" => :overdue_handlers,
    "quarantined_messages" => :quarantined_messages,
    "quarantine_bytes" => :quarantine_bytes,
    "quarantine_enabled" => :quarantine_enabled,
    "quarantine_available" => :quarantine_available
  }
  @max_count 1_000_000_000
  @max_bytes 1_099_511_627_776

  def record(state, hook, payload) do
    with :ok <- validate(payload),
         %{client_id: id, runtime_ref: ref} <- Map.get(state.delivery.client_presence, hook),
         true <- id == payload["client_id"] and ref == payload["runtime_ref"],
         true <- current_or_last?(Map.get(state.delivery.clients, hook), id, ref) do
      previous = get_in(state.delivery.client_presence, [hook, :runtime_report])

      if previous && previous.runtime_ref == ref && previous.sequence >= payload["sequence"] do
        Transition.reply(state, {:ok, %{ok: true}})
      else
        report = %{
          runtime_ref: ref,
          sequence: payload["sequence"],
          received_ms: now(),
          reported_at: DateTime.utc_now(),
          values: Map.take(payload, @gauges ++ ~w(phase quarantine_enabled quarantine_available))
        }

        # Reporting never touches a lease, contact timestamp, batch or queue.
        state = put_in(state.delivery.client_presence[hook].runtime_report, report)
        Transition.reply(state, {:ok, %{ok: true}})
      end
    else
      {:error, _} = error -> Transition.reply(state, error)
      _ -> Transition.reply(state, {:error, :client_lease_lost})
    end
  end

  def snapshot(state, hook, id) do
    observed = Map.get(state.delivery.client_presence, hook) || %{}

    case Map.get(observed, :runtime_report) do
      %{values: values} = report when observed.client_id == id ->
        current = Map.get(state.delivery.clients, hook)

        active? =
          (not is_nil(current) and current.client_id == id) &&
            current.runtime_ref == report.runtime_ref && live?(current)

        age = max(now() - report.received_ms, 0)

        status =
          cond do
            not active? -> "session_inactive"
            age >= @stale_ms -> "stale"
            true -> "fresh"
          end

        values = Map.new(values, fn {key, value} -> {Map.fetch!(@fields, key), value} end)

        Map.merge(values, %{
          reported_at: report.reported_at,
          age_ms: age,
          stale_after_ms: @stale_ms,
          stale: status != "fresh",
          status: status
        })

      _ ->
        nil
    end
  end

  defp validate(p) when is_map(p) do
    valid =
      map_size(p) == length(@keys) and Enum.all?(Map.keys(p), &(&1 in @keys)) and
        Enum.all?(~w(client_id runtime_ref), &(is_binary(p[&1]) and byte_size(p[&1]) in 1..128)) and
        is_integer(p["sequence"]) and p["sequence"] in 1..9_007_199_254_740_991 and
        p["phase"] in @phases and
        Enum.all?(@gauges, &(is_integer(p[&1]) and p[&1] >= 0)) and
        p["active_handlers"] <= 64 and p["overdue_handlers"] <= p["active_handlers"] and
        p["quarantined_messages"] <= @max_count and p["quarantine_bytes"] <= @max_bytes and
        is_boolean(p["quarantine_enabled"]) and is_boolean(p["quarantine_available"])

    if valid, do: :ok, else: {:error, :invalid_payload}
  end

  defp validate(_), do: {:error, :invalid_payload}
  defp current_or_last?(nil, _, _), do: true
  defp current_or_last?(%{client_id: id, runtime_ref: ref}, id, ref), do: true
  defp current_or_last?(_, _, _), do: false
  defp live?(%{transport: :websocket}), do: true
  defp live?(%{timer: timer}) when is_reference(timer), do: (Process.read_timer(timer) || 0) > 0
  defp live?(_), do: false
  defp now, do: System.monotonic_time(:millisecond)
end
