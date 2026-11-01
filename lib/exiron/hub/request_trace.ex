defmodule Exiron.Hub.RequestTrace do
  @moduledoc false

  @limit 500
  @steps 32
  @terminal [:completed, :expired, :delivery_unknown, :failed, :cancelled]

  def start(state, id, message, hook, route_id) do
    now = System.monotonic_time(:millisecond)

    trace = %{
      delivery: nil,
      handler: nil,
      id: id,
      hook: hook,
      chat_id: message.chat_id,
      bot_name: message.bot_name,
      message_id: message.message_id,
      route_id: route_id,
      client_id: nil,
      started_at: now,
      phase_started_at: now,
      at: DateTime.utc_now(),
      status: :queued,
      elapsed_ms: 0,
      deliveries: 0,
      omitted_steps: 0,
      steps:
        Enum.with_index([:received, :route_selected, :queued], fn kind, i ->
          %{id: "#{id}-#{i}", kind: kind, elapsed_ms: 0, at: DateTime.utc_now(), detail: nil}
        end),
      step_sequence: 3
    }

    order = [id | state.activity.trace_order] |> Enum.take(@limit)
    traces = state.activity.traces |> Map.put(id, trace) |> Map.take(order)

    %{
      state
      | activity: %{
          state.activity
          | traces: traces,
            trace_order: order,
            trace_revision: state.activity.trace_revision + 1
        }
    }
  end

  def record(state, id, kind, opts \\ []) do
    case Map.fetch(state.activity.traces, id) do
      :error ->
        state

      {:ok, trace} ->
        elapsed = max(System.monotonic_time(:millisecond) - trace.started_at, 0)

        step = %{
          id: "#{id}-#{trace.step_sequence}",
          kind: kind,
          elapsed_ms: elapsed,
          at: DateTime.utc_now(),
          detail: Keyword.get(opts, :detail)
        }

        steps = trace.steps ++ [step]
        omitted = if length(steps) > @steps, do: 1, else: 0

        steps =
          if omitted == 1, do: Enum.take(steps, 3) ++ Enum.take(steps, -(@steps - 3)), else: steps

        status = Keyword.get(opts, :status, trace.status)

        status =
          if trace.status in @terminal and status not in @terminal, do: trace.status, else: status

        trace = %{
          trace
          | steps: steps,
            step_sequence: trace.step_sequence + 1,
            elapsed_ms: elapsed,
            status: status,
            phase_started_at:
              if(phase(status) == phase(trace.status),
                do: trace.phase_started_at,
                else: System.monotonic_time(:millisecond)
              ),
            omitted_steps: trace.omitted_steps + omitted,
            client_id: Keyword.get(opts, :client_id, trace.client_id),
            deliveries: trace.deliveries + if(kind == :client_delivered, do: 1, else: 0)
        }

        state = put_in(state.activity.traces[id], trace)
        put_in(state.activity.trace_revision, state.activity.trace_revision + 1)
    end
  end

  def delivery(state, id, diagnostic) do
    if Map.has_key?(state.activity.traces, id) do
      state = put_in(state.activity.traces[id].delivery, diagnostic)
      update_in(state.activity.trace_revision, &(&1 + 1))
    else
      state
    end
  end

  def items(state, items, kind, opts \\ []) do
    Enum.reduce(items, state, fn
      %{msgtype: "request", req_id: id}, acc -> record(acc, id, kind, opts)
      _, acc -> acc
    end)
  end

  def list(state, opts \\ []) do
    now = System.monotonic_time(:millisecond)

    Enum.map(state.activity.trace_order, fn id ->
      trace = snapshot(state, state.activity.traces[id], now)

      if opts[:details],
        do: trace,
        else:
          trace
          |> Map.delete(:steps)
          |> Map.update(:delivery, nil, fn d -> if d, do: Map.delete(d, :parts) end)
    end)
  end

  def fetch(state, id),
    do: snapshot(state, Map.get(state.activity.traces, id), System.monotonic_time(:millisecond))

  defp snapshot(_state, nil, _now), do: nil

  defp snapshot(state, trace, now) do
    pending = Map.get(state.delivery.pending, trace.id)
    waiting = if pending && trace.status not in @terminal, do: phase(trace.status)

    expires_in =
      case pending do
        %{timer: timer} when is_reference(timer) -> Process.read_timer(timer) || 0
        _ -> nil
      end

    trace
    |> Map.drop([:started_at, :phase_started_at, :step_sequence])
    |> Map.merge(%{
      age_ms: max(now - trace.started_at, 0),
      pending?: not is_nil(pending),
      client_presence: Exiron.Hub.ClientPresence.for_request(state, trace, pending),
      delivery_progress:
        if(pending,
          do: Exiron.Hub.RequestCancellation.delivery_snapshot(state, trace.id, pending)
        ),
      cancellation:
        case Map.get(state.delivery.cancellations, trace.id) do
          %{result: result} -> result
          _ -> nil
        end,
      expires_in_ms: expires_in,
      wait_phase: waiting,
      waiting_ms: if(waiting, do: max(now - trace.phase_started_at, 0))
    })
  end

  defp phase(:queued), do: :client_queue
  defp phase(status) when status in [:delivered, :awaiting_response], do: :client
  defp phase(:handler_retrying), do: :handler_retry
  defp phase(:handler_exhausted), do: :handler_failed
  defp phase(:sending), do: :telegram
  defp phase(:send_failed), do: :retry
  defp phase(_), do: nil
end
