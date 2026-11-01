defmodule Exiron.Hub.RequestCancellation do
  @moduledoc false
  alias Exiron.Hub.{
    ClientDeliveries,
    Effect,
    PendingRequests,
    RecentReplies,
    RequestQueue,
    RequestTrace,
    Transition
  }

  @limit 500

  def check(state, id, hook) do
    case Map.get(state.delivery.cancellations, id) do
      %{hook: ^hook} -> {:error, :request_cancelled}
      %{hook: _} -> {:error, :request_not_assigned}
      nil -> :ok
    end
  end

  def cancel(state, id, hook) do
    case Map.get(state.delivery.cancellations, id) do
      %{hook: ^hook, result: result} -> Transition.reply(state, {:ok, result})
      %{hook: _} -> Transition.reply(state, {:error, :request_not_assigned})
      nil -> cancel_pending(state, id, hook)
    end
  end

  # Trusted dashboard entry point, like configuration/reload operations. Hook
  # ownership comes from current Hub state, never from browser parameters.
  def cancel_from_monitor(%{enabled?: true} = state, id)
      when is_binary(id) and byte_size(id) in 1..128 do
    case Map.get(state.delivery.pending, id) || Map.get(state.delivery.cancellations, id) do
      %{hook: hook} -> cancel(state, id, hook)
      _ -> Transition.reply(state, {:error, :request_not_found})
    end
  end

  def cancel_from_monitor(state, _id), do: Transition.reply(state, {:error, :request_not_found})

  def delivery_snapshot(state, id, pending) do
    active =
      Enum.any?(state.delivery.sends, fn
        {_, %{command: %{request_id: ^id}, attempt_in_flight?: true}} -> true
        _ -> false
      end)

    status =
      cond do
        active or Map.get(pending, :delivery_unknown?, false) ->
          "unknown"

        Map.get(pending, :delivered?, false) or is_integer(Map.get(pending, :response_message_id)) ->
          "partial"

        true ->
          "not_started"
      end

    ids =
      if Map.get(pending, :delivered?, false) do
        Map.get(pending, :delivery_message_ids, [])
      else
        (Map.get(pending, :text_message_ids, []) ++
           List.wrap(Map.get(pending, :response_message_id)))
        |> Enum.uniq()
      end

    %{delivery_status: status, message_ids: ids}
  end

  defp cancel_pending(state, id, hook) do
    case Map.get(state.delivery.pending, id) do
      nil ->
        Transition.reply(state, {:error, :request_not_found})

      %{hook: other} when other != hook ->
        Transition.reply(state, {:error, :request_not_assigned})

      pending ->
        result = delivery_snapshot(state, id, pending) |> Map.merge(%{ok: true, cancelled: true})
        {state, effects} = stop_sends(state, id, :request_cancelled)

        state =
          state
          |> PendingRequests.delete(id)
          |> RequestQueue.remove(hook, id)
          |> ClientDeliveries.remove_request(hook, id)
          |> RecentReplies.forget(id)
          |> Exiron.Hub.DeliveryDiagnostics.close_request(id, hook, "cancelled")
          |> RequestTrace.record(id, :request_cancelled,
            status: :cancelled,
            detail: "Delivery: #{result.delivery_status}"
          )

        order = [id | state.delivery.cancellation_order] |> Enum.take(@limit)

        records =
          state.delivery.cancellations
          |> Map.put(id, %{hook: hook, result: result})
          |> Map.take(order)

        state = %{
          state
          | delivery: %{state.delivery | cancellations: records, cancellation_order: order}
        }

        Transition.new(state,
          reply: {:ok, result},
          effects:
            effects ++
              [
                Effect.cancel_timer(pending.timer),
                Effect.deliver_socket_queues(),
                Effect.broadcast_status()
              ]
        )
    end
  end

  def stop_sends(state, id, reason) do
    {stopped, retained} =
      Enum.split_with(state.delivery.sends, fn {_, task} -> task.command.request_id == id end)

    state = %{state | delivery: %{state.delivery | sends: Map.new(retained)}}

    Enum.reduce(stopped, {state, []}, fn {_, task}, {state, effects} ->
      Process.demonitor(task.monitor, [:flush])

      diagnostic =
        Exiron.Hub.DeliveryDiagnostics.finish(
          task.diagnostic,
          if(reason == :request_cancelled, do: "cancelled", else: "expired"),
          reason,
          false
        )

      state = Exiron.Hub.DeliveryDiagnostics.retain(state, diagnostic)

      reply =
        Exiron.Hub.DeliveryDiagnostics.enrich_effect(
          Effect.reply(task.from, {:error, reason}),
          task.command,
          diagnostic
        )

      {state,
       effects ++ [Effect.terminate_task(task.pid), Effect.cancel_timer(task.timer), reply]}
    end)
  end
end
