defmodule Exiron.Hub.DeliveryReceipt do
  @moduledoc false

  # Only Telegram-confirmed IDs are exposed. Never include bot credentials or payloads.
  def from_messages(messages) do
    Enum.flat_map(messages, fn message ->
      ids =
        ([message.message_id] ++ message.text_message_ids ++ message.media_message_ids)
        |> Enum.filter(&(is_integer(&1) and &1 > 0))
        |> Enum.uniq()

      if ids == [] do
        []
      else
        [
          %{
            service_id: message.service_id,
            chat_id: message.chat_id,
            message_thread_id: message.message_thread_id,
            message_ids: ids
          }
        ]
      end
    end)
  end
end
