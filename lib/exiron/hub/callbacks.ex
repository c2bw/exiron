defmodule Exiron.Hub.Callbacks do
  @moduledoc false
  alias Exiron.Hub.{
    Effect,
    IncomingDeduplicator,
    InlineKeyboard,
    Message,
    PendingRequests,
    QueueState,
    RequestQueue,
    Runtime,
    Transition
  }

  # Discard the source message body and Telegram-only fields before crossing
  # into the Hub mailbox; callback delivery needs only this small identity map.
  def sanitize(query) when is_map(query) do
    from = Exiron.Hub.Telegram.MessageParser.metadata(%{from: Map.get(query, :from)}).from

    source =
      case Map.get(query, :message) do
        %{chat: %{id: chat}, message_id: id} -> %{chat: %{id: chat}, message_id: id}
        _ -> nil
      end

    %{id: Map.get(query, :id), data: Map.get(query, :data), from: from, message: source}
  end

  def sanitize(_), do: %{}

  def handle(state, token, query) do
    with true <- state.enabled?,
         %{id: id, from: from, message: %{chat: %{id: chat}, message_id: message_id}} <- query,
         true <- is_binary(id) and byte_size(id) in 1..256,
         {:ok, binding} <- InlineKeyboard.lookup(state, token, query),
         true <-
           Map.get(binding, :product_action) in ["command", "command_input"] or
             Map.has_key?(state.router.hooks, binding.hook) do
      cond do
        Map.get(binding, :product_action) in ["command", "command_input"] ->
          Exiron.Hub.CommandDiscovery.select(state, binding, token, query)

        Map.has_key?(binding, :product_action) ->
          Exiron.Hub.RequestInteraction.handle(state, binding, from)

        true ->
          metadata = Exiron.Hub.Telegram.MessageParser.metadata(%{from: from})

          message =
            Message.incoming(Exiron.Hub.Telegram.service_id(), chat, "callback", binding.data,
              bot_token: token,
              bot_name: binding.bot_name,
              message_id: message_id,
              message_thread_id: binding.message_thread_id,
              from: metadata.from,
              callback_query: %{id: id, origin_req_id: binding.origin_req_id}
            )

          message = %{
            message
            | inline_keyboard: binding.inline_keyboard,
              callback_buttons: binding.callback_buttons,
              text_message_ids: binding.text_message_ids
          }

          if Exiron.Hub.AccessPolicy.callback_allowed?(
               state.router,
               binding.hook,
               message.service_id,
               chat,
               from
             ),
             do: accept(state, message, binding.hook),
             else: Transition.reply(state, {:error, :unavailable})
      end
    else
      _ -> Transition.reply(state, {:error, :unavailable})
    end
  end

  defp accept(state, message, hook) do
    case IncomingDeduplicator.remember(state, message) do
      {:duplicate, state} ->
        Transition.reply(state, :ok)

      {:new, state} ->
        admission =
          if QueueState.hook_available?(state, hook),
            do: RequestQueue.available?(state, hook, message),
            else: {:error, :unavailable}

        if admission == :ok do
          {_id, state} =
            PendingRequests.create(state, message, hook, state.settings.pending_timeout)

          state
          |> Runtime.record_event("incoming", "telegram", hook, message, "callback")
          |> Transition.reply(:ok)
          |> Transition.effect(Effect.deliver_socket_queues())
          |> Transition.effect(Effect.broadcast_status())
        else
          state =
            if admission == {:error, :max_buffered_bytes},
              do:
                state
                |> Exiron.Hub.BufferBudget.reject(:requests)
                |> Exiron.Hub.DeliveryHealth.reject(hook, :overloaded),
              else: state

          state
          |> Transition.reply({:error, :unavailable})
          |> Transition.effect(Effect.broadcast_status())
        end
    end
  end
end
