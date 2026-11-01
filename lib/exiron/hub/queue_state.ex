defmodule Exiron.Hub.QueueState do
  @moduledoc false

  alias Exiron.Hub.{
    ClientState,
    DeliveryHealth,
    Event,
    Message,
    PendingRequest,
    Queue,
    QueueBuffer,
    Router
  }

  def enqueue_listener_messages(state, message, skip_hooks \\ []) do
    address = message |> Message.address() |> Message.base_address()
    skip_hooks = MapSet.new(skip_hooks)

    state
    |> listening_hooks()
    |> Enum.reduce({state, []}, fn hook, {state, events} ->
      if MapSet.member?(skip_hooks, hook) and not hook_listen_all?(state, hook) do
        {state, events}
      else
        maybe_enqueue_listener_message(state, events, hook, address, message)
      end
    end)
    |> then(fn {state, events} -> {state, Enum.reverse(events)} end)
  end

  def queue_listener_message(state, hook, message) do
    buffer = Map.get(state.delivery.queues, hook, QueueBuffer.new())

    if Exiron.Hub.BufferBudget.available?(state, Message.queued_payload_size(message)) do
      item = Message.to_listen(message)
      {queue, dropped} = QueueBuffer.push(buffer, item, Queue.listener_bounds(state, hook))
      # Listener churn may discard stale listeners, but cannot evict routed work.
      kept = MapSet.new(for %{msgtype: "request", req_id: id} <- queue.items, do: id)

      retained? =
        Enum.all?(buffer.items, fn
          %{msgtype: "request", req_id: id} -> MapSet.member?(kept, id)
          _ -> true
        end)

      {queue, dropped} = if retained?, do: {queue, dropped}, else: {buffer, 1}
      Exiron.Telemetry.queue(queue.count, queue.bytes, dropped, hook)
      {put_in(state.delivery.queues[hook], queue), dropped}
    else
      Exiron.Telemetry.queue(buffer.count, buffer.bytes, 1, hook)
      {Exiron.Hub.BufferBudget.reject(state, :listeners), 1}
    end
  end

  def hook_available?(state, hook) do
    Map.has_key?(state.delivery.clients, hook) or
      Enum.any?(state.delivery.pending, fn {_request_id, pending} ->
        pending.hook == hook and claimed?(pending)
      end)
  end

  def hook_listening?(state, hook) do
    case ClientState.get(state, hook) do
      %{listen?: listen?} -> listen?
      nil -> false
    end
  end

  def hook_listen_all?(state, hook) do
    case ClientState.get(state, hook) do
      %{listen_mode: :all} -> true
      _client -> false
    end
  end

  def hook_snapshots(state) do
    Enum.map(Router.hooks(state.router), &hook_snapshot(state, &1))
  end

  def hook_snapshots(%{router: %Router{hooks: hooks}} = state, hook) when is_binary(hook) do
    if Map.has_key?(hooks, hook), do: [hook_snapshot(state, hook)], else: []
  end

  defp listening_hooks(state) do
    state.delivery.clients
    |> Map.keys()
    |> Enum.filter(&hook_listening?(state, &1))
    |> Enum.sort()
  end

  defp hook_snapshot(state, hook) do
    queue = Map.get(state.delivery.queues, hook, QueueBuffer.new())

    health =
      Map.merge(DeliveryHealth.for_hook(state, hook), %{
        queued: queue.count,
        queued_bytes: queue.bytes,
        pending:
          Enum.count(state.delivery.pending, fn {_id, request} -> request.hook == hook end),
        in_flight_send_limit: Exiron.Hub.SendTasks.hook_limit(state),
        in_flight_send_bytes: Exiron.Hub.SendBudget.usage(state, hook),
        in_flight_send_bytes_limit: Exiron.Hub.SendBudget.hook_limit(state),
        in_flight_sends: Exiron.Hub.SendTasks.in_flight_for_hook(state, hook)
      })

    %{
      name: hook,
      client: Exiron.Hub.ClientPresence.snapshot(state, hook),
      connected: hook_available?(state, hook),
      listening: hook_listening?(state, hook),
      queued: queue.count,
      health: health
    }
  end

  defp maybe_enqueue_listener_message(state, events, hook, address, message) do
    if Router.can_listen?(state.router, hook, address) and
         Exiron.Hub.AccessPolicy.callback_allowed?(
           state.router,
           hook,
           message.service_id,
           message.chat_id,
           message.from
         ) do
      event = Event.new("outgoing", "client", hook, message, "listen")
      {state, dropped} = queue_listener_message(state, hook, message)

      {state, [event | listener_drop_events(events, hook, message, dropped)]}
    else
      {state, events}
    end
  end

  defp listener_drop_events(events, _hook, _message, 0), do: events

  defp listener_drop_events(events, hook, message, dropped) do
    drop_message = %{
      message
      | data: "Dropped #{dropped} listen #{pluralize(dropped, "message")} for #{hook}."
    }

    [Event.new("outgoing", "client", hook, drop_message, "listen_dropped") | events]
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp claimed?(%PendingRequest{claimed?: claimed?}), do: claimed?
  defp claimed?(pending), do: Map.get(pending, :claimed?, false)
end
