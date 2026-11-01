defmodule Exiron.Hub.ProcessEvents do
  @moduledoc false

  alias Exiron.Hub.{
    ClientSessions,
    Effect,
    PendingRequests,
    SendTasks,
    State,
    TelegramEvents,
    Transition
  }

  @spec complete_socket_delivery(State.t(), String.t(), String.t(), pid(), reference()) ::
          Transition.t()
  def complete_socket_delivery(state, hook, client_id, pid, delivery_ref) do
    case ClientSessions.complete_socket_delivery(state, hook, client_id, pid, delivery_ref) do
      {:completed, state} ->
        Transition.new(state,
          effects: [Effect.deliver_socket_queues(), Effect.broadcast_status()]
        )

      {:stale, state} ->
        Transition.new(state)
    end
  end

  @spec expire_request(State.t(), String.t()) :: Transition.t()
  def expire_request(state, request_id) do
    hook =
      case Map.get(state.delivery.pending, request_id) do
        %{hook: hook} -> hook
        _ -> nil
      end

    case PendingRequests.expire(state, request_id) do
      {:expired, state} ->
        {state, effects} =
          Exiron.Hub.RequestCancellation.stop_sends(state, request_id, :request_not_found)

        # Remove expired requests from retained HTTP/socket batches as well.
        state =
          Enum.reduce(
            Map.keys(state.delivery.clients),
            state,
            &Exiron.Hub.ClientDeliveries.remove_request(&2, &1, request_id)
          )

        state = Exiron.Hub.DeliveryDiagnostics.close_request(state, request_id, hook, "expired")

        Transition.new(state,
          effects: effects ++ [Effect.deliver_socket_queues(), Effect.broadcast_status()]
        )

      {:unchanged, state} ->
        Transition.new(state)
    end
  end

  @spec expire_client(State.t(), String.t(), String.t(), reference()) :: Transition.t()
  def expire_client(state, hook, client_id, lease) do
    state
    |> ClientSessions.expire_client(hook, client_id, lease)
    |> Transition.new(effects: [Effect.broadcast_status()])
  end

  @spec send_complete(State.t(), reference(), term()) :: Transition.t()
  def send_complete(state, ref, result), do: SendTasks.finish(state, ref, result)

  @spec send_timeout(State.t(), reference()) :: Transition.t()
  def send_timeout(state, ref), do: SendTasks.expire(state, ref)

  @spec down(State.t(), reference(), pid(), term()) :: Transition.t()
  def down(state, monitor, pid, reason) do
    case ClientSessions.disconnect_down_socket(state, monitor, pid) do
      {:disconnected, state} ->
        Transition.new(state, effects: [Effect.broadcast_status()])

      {:unchanged, state} ->
        send_or_poller_down(state, monitor, pid, reason)
    end
  end

  defp send_or_poller_down(state, monitor, pid, reason) do
    case SendTasks.task_down(state, monitor, pid, reason) do
      {:failed, transition} -> transition
      {:unchanged, state} -> TelegramEvents.poller_down(state, monitor, pid)
    end
  end
end
