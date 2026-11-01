defmodule ExironClient.ConversationOrder do
  @moduledoc false

  def lanes(messages) do
    {order, groups} =
      Enum.reduce(messages, {[], %{}}, fn message, {order, groups} ->
        key = key(message)
        order = if Map.has_key?(groups, key), do: order, else: [key | order]
        {order, Map.update(groups, key, [message], &[message | &1])}
      end)

    order |> Enum.reverse() |> Enum.map(&Enum.reverse(Map.fetch!(groups, &1)))
  end

  defp key(%{service_id: service, chat_id: chat, message_thread_id: topic})
       when is_integer(service) and service != 0 and is_integer(chat) and chat != 0,
       do: {service, chat, topic}

  defp key(_), do: :unknown
end
