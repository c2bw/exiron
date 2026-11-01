defmodule ExironClient.Wire.Message do
  @moduledoc false

  alias ExironClient.{Error, Message, Wire}

  @spec decode(map(), atom()) :: {:ok, Message.t()} | {:error, Error.t()}
  def decode(%{} = params, fallback_type) do
    with {:ok, data} <- Wire.Payload.decode_message(Map.get(params, "data")),
         {:ok, items} <- album_items(params, data) do
      {:ok,
       %Message{
         msgtype: Map.get(params, "msgtype", Atom.to_string(fallback_type)),
         req_id: Map.get(params, "req_id"),
         message_id: Map.get(params, "message_id"),
         reply_to_message_id: Map.get(params, "reply_to_message_id"),
         from: Map.get(params, "from"),
         service_id: Map.get(params, "service_id"),
         chat_id: Map.get(params, "chat_id"),
         instance: Map.get(params, "instance"),
         datatype: Map.get(params, "datatype"),
         sticker_id: Map.get(params, "sticker_id"),
         sticker_emoji: Map.get(params, "sticker_emoji"),
         emoji_list: Map.get(params, "emoji_list", []),
         data: data,
         message_thread_id: Map.get(params, "message_thread_id"),
         media_group_id: Map.get(params, "media_group_id"),
         caption: Map.get(params, "caption"),
         entities: Map.get(params, "entities"),
         caption_entities: Map.get(params, "caption_entities"),
         file_name: Map.get(params, "file_name"),
         mime_type: Map.get(params, "mime_type"),
         callback_query: Map.get(params, "callback_query"),
         followup_req_id: Map.get(params, "followup_req_id"),
         media_items: items
       }}
    end
  end

  def decode(_params, _fallback_type) do
    {:error, Error.new(:invalid_response, "expected message to be an object")}
  end

  defp album_items(%{"datatype" => "album"}, data), do: ExironClient.MediaItem.decode(data)
  defp album_items(_, _), do: {:ok, []}

  @spec decode_list([map()], atom()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def decode_list(messages, fallback_type) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case decode(message, fallback_type) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end
end
