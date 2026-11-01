defmodule Exiron.Hub.RecentReplies do
  @moduledoc false
  @limit 500

  def remember(state, id, hook, message) do
    state = Exiron.Hub.InlineKeyboard.remember(state, hook, message)

    if is_integer(message.message_id) and message.message_id > 0 do
      context =
        case Map.get(state.delivery.pending, id) do
          %{interaction_context: context} -> context
          _ -> get_in(state.delivery.replies, [id, :interaction_context])
        end

      receipt = %{
        interaction_context: context,
        media_message_ids: message.media_message_ids,
        hook: hook,
        service_id: message.service_id,
        chat_id: message.chat_id,
        message_id: message.message_id,
        reply_to_message_id: message.reply_to_message_id,
        text_message_ids: message.text_message_ids,
        message_thread_id: message.message_thread_id,
        bot_token: message.bot_token,
        bot_name: message.bot_name,
        inline_keyboard: message.inline_keyboard,
        callback_buttons: message.callback_buttons,
        busy?: false
      }

      order = [id | List.delete(state.delivery.reply_order, id)] |> Enum.take(@limit)
      replies = state.delivery.replies |> Map.put(id, receipt) |> Map.take(order)
      %{state | delivery: %{state.delivery | replies: replies, reply_order: order}}
    else
      state
    end
  end

  def forget(state, id) do
    %{
      state
      | delivery: %{
          state.delivery
          | replies: Map.delete(state.delivery.replies, id),
            reply_order: List.delete(state.delivery.reply_order, id)
        }
    }
  end

  def take(state, id, hook) do
    with :ok <- Exiron.Hub.RequestCancellation.check(state, id, hook),
         do: take_reply(state, id, hook)
  end

  defp take_reply(state, id, hook) do
    case Map.get(state.delivery.replies, id) do
      nil -> {:error, :request_not_found}
      %{hook: other} when other != hook -> {:error, :request_not_assigned}
      %{busy?: true} -> {:error, :request_in_flight}
      receipt -> {:ok, receipt}
    end
  end

  def busy(state, id, busy?) do
    case Map.get(state.delivery.replies, id) do
      nil -> state
      receipt -> put_in(state.delivery.replies[id], %{receipt | busy?: busy?})
    end
  end
end
