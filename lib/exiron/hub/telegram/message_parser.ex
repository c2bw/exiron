defmodule Exiron.Hub.Telegram.MessageParser do
  @moduledoc false

  def content(%{text: text}) when is_binary(text) and text != "",
    do: {:ok, "text", text}

  def content(message) do
    case file_message(message) do
      {:ok, file_id, datatype} -> {:file, file_id, datatype, %{}}
      {:ok, file_id, datatype, opts} -> {:file, file_id, datatype, opts}
      :ignore -> caption_from_message(message)
    end
  end

  def metadata(message) do
    %{
      message_id: message_id(message),
      reply_to_message_id: reply_to_message_id(message),
      from: sender(message),
      message_thread_id: Map.get(message, :message_thread_id),
      media_group_id: Map.get(message, :media_group_id),
      caption: Map.get(message, :caption),
      entities: Exiron.Hub.MessageMetadata.sanitize_entities(Map.get(message, :entities)),
      caption_entities:
        Exiron.Hub.MessageMetadata.sanitize_entities(Map.get(message, :caption_entities)),
      file_name: media_metadata(message, :file_name),
      mime_type: media_metadata(message, :mime_type)
    }
  end

  defp media_metadata(message, key) do
    Enum.find_value([:document, :audio, :voice, :video, :video_note, :animation], fn field ->
      case Map.get(message, field) do
        media when is_map(media) -> Map.get(media, key)
        _ -> nil
      end
    end)
  end

  defp caption_from_message(%{caption: caption}) when is_binary(caption) and caption != "",
    do: {:ok, "text", caption}

  defp caption_from_message(_message), do: :ignore

  defp message_id(%{message_id: message_id}) when is_integer(message_id), do: message_id
  defp message_id(_message), do: nil

  defp reply_to_message_id(%{reply_to_message: %{message_id: message_id}})
       when is_integer(message_id),
       do: message_id

  defp reply_to_message_id(_message), do: nil

  defp sender(%{from: from}) when is_map(from) do
    %{
      id: Map.get(from, :id),
      is_bot: Map.get(from, :is_bot),
      first_name: Map.get(from, :first_name),
      last_name: Map.get(from, :last_name),
      username: Map.get(from, :username),
      language_code: Map.get(from, :language_code)
    }
  end

  defp sender(_message), do: nil

  defp file_message(%{audio: %{file_id: file_id}}), do: {:ok, file_id, "audio"}
  defp file_message(%{voice: %{file_id: file_id}}), do: {:ok, file_id, "audio"}
  defp file_message(%{video: %{file_id: file_id}}), do: {:ok, file_id, "video"}
  defp file_message(%{video_note: %{file_id: file_id}}), do: {:ok, file_id, "video"}

  defp file_message(%{photo: photos}) when is_list(photos) and photos != [],
    do: {:ok, List.last(photos).file_id, "image"}

  defp file_message(%{document: %{file_id: file_id}}), do: {:ok, file_id, "file"}
  defp file_message(%{animation: %{file_id: file_id}}), do: {:ok, file_id, "file"}

  defp file_message(%{sticker: %{file_id: file_id} = sticker}) do
    opts =
      case Map.get(sticker, :emoji) do
        emoji when is_binary(emoji) and emoji != "" ->
          %{sticker_id: file_id, sticker_emoji: emoji}

        _emoji ->
          %{sticker_id: file_id}
      end

    {:ok, file_id, "file", Map.put(opts, :file_unique_id, Map.get(sticker, :file_unique_id))}
  end

  defp file_message(_message), do: :ignore
end
