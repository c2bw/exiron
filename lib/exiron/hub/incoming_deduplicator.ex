defmodule Exiron.Hub.IncomingDeduplicator do
  @moduledoc false

  alias Exiron.Hub.{History, Message}

  @max_keys 500

  def remember(state, %Message{callback_query: %{id: id}}) do
    remember_key(state, {:callback, id})
  end

  def remember(state, %Message{message_id: message_id} = message) when is_integer(message_id) do
    key = {message.service_id, message.chat_id, message_id}

    remember_key(state, key)
  end

  def remember(state, _message), do: {:new, state}

  defp remember_key(state, key) do
    if MapSet.member?(state.lookups.incoming_message_keys, key) do
      {:duplicate, state}
    else
      order = History.prepend(state.lookups.incoming_message_key_order, key, @max_keys)

      {:new,
       %{
         state
         | lookups: %{
             state.lookups
             | incoming_message_keys: MapSet.new(order),
               incoming_message_key_order: order
           }
       }}
    end
  end
end
