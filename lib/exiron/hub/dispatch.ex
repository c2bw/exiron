defmodule Exiron.Hub.Dispatch do
  @moduledoc false

  alias Exiron.Hub.{
    Event,
    DeliveryHealth,
    History,
    Identifier,
    Message,
    PendingRequests,
    QueueState,
    RequestQueue,
    Router,
    SendCommand
  }

  @max_overload_events 50

  def incoming_service_message(state, %Message{} = message, opts \\ []) do
    pending_timeout = Keyword.fetch!(opts, :pending_timeout)
    received = Event.new("incoming", "telegram", nil, message, "received")

    case Exiron.Hub.GuidedCommands.resolve(state, message) do
      :blocked ->
        notice =
          Message.outgoing(
            message.service_id,
            message.chat_id,
            "text",
            "This input prompt is no longer available. Send /help to choose again.",
            message.bot_token,
            bot_name: message.bot_name,
            message_thread_id: message.message_thread_id,
            reply_to_message_id: message.message_id,
            parse_mode: "plain"
          )

        {state, [received], [SendCommand.background(:interaction, nil, notice)]}

      {:ok, route, guided} ->
        dispatch(state, guided, {:ok, route}, pending_timeout, received)

      :skip ->
        {route_result, message} = Exiron.Hub.ConversationRouting.resolve(state, message)

        case Exiron.Hub.CommandDiscovery.response(state.router, message, route_result) do
          nil -> dispatch(state, message, route_result, pending_timeout, received)
          response -> {state, [received], [SendCommand.background(:interaction, nil, response)]}
        end
    end
  end

  defp dispatch(state, message, route_result, pending_timeout, received) do
    case route_result do
      {:ok, route} ->
        if Exiron.Hub.AccessPolicy.allowed?(route, message.from),
          do: dispatch_allowed(state, message, route_result, pending_timeout, received),
          else: {state, [received], [SendCommand.background(:interaction, nil, denied(message))]}

      :error ->
        dispatch_allowed(state, message, route_result, pending_timeout, received)
    end
  end

  defp denied(message),
    do:
      Message.outgoing(
        message.service_id,
        message.chat_id,
        "text",
        "You cannot use this command.",
        message.bot_token,
        bot_name: message.bot_name,
        message_thread_id: message.message_thread_id,
        reply_to_message_id: message.message_id,
        parse_mode: "plain"
      )

  defp dispatch_allowed(state, message, route_result, pending_timeout, received) do
    # Admit routed work before spending the remaining budget on listener copies.
    {state, route_events, sends} =
      dispatch_routed_message(state, message, route_result, pending_timeout)

    {state, listener_events} =
      QueueState.enqueue_listener_messages(state, message, routed_hooks(route_result))

    {state, [received | listener_events] ++ route_events, sends}
  end

  defp dispatch_routed_message(state, message, route_result, pending_timeout) do
    case route_result do
      {:ok, route} -> dispatch_to_route(state, message, route, pending_timeout)
      :error -> {state, [], []}
    end
  end

  defp routed_hooks({:ok, route}), do: [route.to]
  defp routed_hooks(:error), do: []

  defp dispatch_to_route(state, message, route, pending_timeout) do
    routed_message = Router.routed_message(message, route)

    cond do
      not QueueState.hook_available?(state, route.to) ->
        notify_hook_unavailable(state, routed_message, route.to)

      true ->
        case RequestQueue.available?(state, route.to, routed_message) do
          :ok -> create_pending_request(state, routed_message, route, pending_timeout)
          {:error, reason} -> notify_hook_overloaded(state, routed_message, route.to, reason)
        end
    end
  end

  defp create_pending_request(state, message, route, pending_timeout) do
    {request_id, state} =
      PendingRequests.create(state, message, route.to, pending_timeout,
        route_id: route.id,
        route: route
      )

    state = Exiron.Hub.GuidedCommands.consume(state, message)
    sends = Exiron.Hub.RequestInteraction.controls(message, route, request_id)
    {state, [Event.new("outgoing", "client", route.to, message, "request")], sends}
  end

  defp notify_hook_unavailable(state, message, hook) do
    state = DeliveryHealth.reject(state, hook, :unavailable)
    unavailable = unavailable_message(message, hook)
    {state, [], [SendCommand.background(:unavailable, hook, unavailable)]}
  end

  defp notify_hook_overloaded(state, message, hook, reason) do
    state = DeliveryHealth.reject(state, hook, :overloaded)

    state =
      if reason == :max_buffered_bytes,
        do: Exiron.Hub.BufferBudget.reject(state, :requests),
        else: state

    overloaded = overloaded_message(message, hook)
    event = Event.new("outgoing", "client", hook, message, "overloaded")

    overload_events =
      History.prepend(
        state.activity.overload_events,
        overload_event(hook, message, reason),
        @max_overload_events
      )

    state = %{state | activity: %{state.activity | overload_events: overload_events}}

    {state, [event], [SendCommand.background(:overloaded, hook, overloaded)]}
  end

  defp unavailable_message(message, hook) do
    Message.outgoing(
      message.service_id,
      message.chat_id,
      "text",
      "Hook #{hook} is not connected.",
      message.bot_token,
      bot_name: message.bot_name
    )
  end

  defp overloaded_message(message, hook) do
    Message.outgoing(
      message.service_id,
      message.chat_id,
      "text",
      "Hook #{hook} is overloaded. Please try again later.",
      message.bot_token,
      bot_name: message.bot_name
    )
  end

  defp overload_event(hook, message, reason) do
    %{
      id: Identifier.new(),
      at: DateTime.utc_now(),
      hook: hook,
      reason: reason,
      service_id: message.service_id,
      chat_id: message.chat_id,
      datatype: message.datatype,
      payload_bytes: Message.payload_size(message)
    }
  end
end
