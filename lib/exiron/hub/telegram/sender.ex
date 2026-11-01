defmodule Exiron.Hub.Telegram.Sender do
  @moduledoc false

  alias Exiron.Hub.{MediaAlbum, Message, MessageMetadata}

  @media_senders %{
    "audio" => {:send_audio, "audio"},
    "video" => {:send_video, "video"},
    "image" => {:send_photo, "image"},
    "file" => {:send_document, "file"}
  }

  def send(token, message) do
    case deliver(token, message) do
      {:ok, _receipt} -> :ok
      result -> result
    end
  end

  def deliver(token, %Message{datatype: "delete", edit_message_id: id} = message) do
    case ExGram.delete_message(message.chat_id, id, token: token) do
      {:error, %ExGram.Error{code: 400, message: reason}} = error ->
        if is_binary(reason) and String.contains?(reason, "message to delete not found"),
          do: {:ok, true},
          else: error

      result ->
        result
    end
  end

  def deliver(token, %Message{datatype: "keyboard", edit_message_id: id} = message)
      when is_integer(id) do
    case ExGram.edit_message_reply_markup(
           [chat_id: message.chat_id, message_id: id, token: token] ++ keyboard_opts(message)
         ) do
      {:error, %ExGram.Error{code: 400, message: reason}} = error ->
        if is_binary(reason) and String.contains?(reason, "message is not modified"),
          do: {:ok, %{message_id: id}},
          else: error

      result ->
        result
    end
  end

  def deliver(token, %Message{datatype: "action"} = message) do
    ExGram.send_chat_action(message.chat_id, message.data, topic_opts(token, message))
  end

  def deliver(token, %Message{datatype: "text", edit_message_id: id} = message)
      when is_integer(id) do
    opts =
      [chat_id: message.chat_id, message_id: id, token: token] ++
        format_opts(message, :entities) ++ keyboard_opts(message)

    case ExGram.edit_message_text(message.data, opts) do
      {:error, %ExGram.Error{code: 400, message: reason}} = error ->
        if is_binary(reason) and String.contains?(reason, "message is not modified"),
          do: {:ok, %{message_id: id}},
          else: error

      result ->
        result
    end
  end

  def deliver(token, %Message{datatype: "text"} = message) do
    opts = topic_opts(token, message) ++ format_opts(message, :entities)

    case ExGram.send_message(message.chat_id, message.data, opts) do
      {:error, reason} = error ->
        if markdown_parse_error?(reason) and Keyword.get(opts, :parse_mode) == "Markdown",
          do:
            ExGram.send_message(message.chat_id, message.data, Keyword.delete(opts, :parse_mode)),
          else: error

      result ->
        result
    end
  end

  def deliver(token, %Message{datatype: "album"} = message) do
    with {:ok, items} <- album_items(message) do
      media = Enum.map(items, &media_item/1)
      ExGram.send_media_group(message.chat_id, media, topic_opts(token, message))
    end
  end

  def deliver(token, %Message{datatype: datatype} = message)
      when is_map_key(@media_senders, datatype) do
    {fun, filename} = Map.fetch!(@media_senders, datatype)
    opts = topic_opts(token, message) ++ caption_opts(message)

    apply(ExGram, fun, [
      message.chat_id,
      {:file_content, message.data, message.file_name || filename},
      opts
    ])
  end

  def deliver(token, %Message{datatype: "sticker"} = message) do
    opts = topic_opts(token, message)

    opts =
      if is_binary(message.sticker_emoji) and message.sticker_emoji != "",
        do: Keyword.put(opts, :emoji, message.sticker_emoji),
        else: opts

    ExGram.send_sticker(message.chat_id, message.data, opts)
  end

  defp topic_opts(token, message) do
    opts = [token: token] ++ keyboard_opts(message) ++ reply_opts(message)

    if message.message_thread_id,
      do: Keyword.put(opts, :message_thread_id, message.message_thread_id),
      else: opts
  end

  defp reply_opts(%{reply_to_message_id: id, edit_message_id: nil, datatype: type})
       when is_integer(id) and id > 0 and type != "action" do
    [
      reply_parameters: %ExGram.Model.ReplyParameters{
        message_id: id,
        allow_sending_without_reply: false
      }
    ]
  end

  defp reply_opts(_), do: []

  defp keyboard_opts(%{force_reply?: true}),
    do: [
      reply_markup: %ExGram.Model.ForceReply{
        force_reply: true,
        selective: true,
        input_field_placeholder: "Type your message"
      }
    ]

  defp keyboard_opts(%{inline_keyboard: nil}), do: []

  defp keyboard_opts(%{inline_keyboard: rows}) do
    buttons =
      Enum.map(rows, fn row -> Enum.map(row, &struct!(ExGram.Model.InlineKeyboardButton, &1)) end)

    [reply_markup: %ExGram.Model.InlineKeyboardMarkup{inline_keyboard: buttons}]
  end

  defp caption_opts(%{caption: caption} = message) when is_binary(caption),
    do: [caption: caption] ++ format_opts(message, :caption_entities)

  defp caption_opts(_), do: []

  defp format_opts(message, field) do
    entities = Map.get(message, field)

    cond do
      is_list(entities) -> [{field, MessageMetadata.telegram_entities(entities)}]
      message.parse_mode == "plain" -> []
      is_binary(message.parse_mode) -> [parse_mode: message.parse_mode]
      field == :entities -> [parse_mode: "Markdown"]
      true -> []
    end
  end

  defp album_items(%{media_items: items}) when is_list(items), do: {:ok, items}
  defp album_items(message), do: MediaAlbum.decode(message.data)

  defp media_item(item) do
    type =
      %{"image" => "photo", "video" => "video", "audio" => "audio", "file" => "document"}[
        item.datatype
      ]

    media = %{
      type: type,
      media: {:file_content, item.data, Map.get(item, :file_name) || item.datatype}
    }

    media =
      if is_binary(Map.get(item, :caption)) do
        media = Map.put(media, :caption, item.caption)

        case Map.get(item, :caption_entities) do
          entities when is_list(entities) ->
            Map.put(media, :caption_entities, MessageMetadata.telegram_entities(entities))

          _ ->
            case Map.get(item, :parse_mode) do
              mode when mode in ["Markdown", "MarkdownV2", "HTML"] ->
                Map.put(media, :parse_mode, mode)

              _ ->
                media
            end
        end
      else
        media
      end

    module =
      %{
        "photo" => ExGram.Model.InputMediaPhoto,
        "video" => ExGram.Model.InputMediaVideo,
        "audio" => ExGram.Model.InputMediaAudio,
        "document" => ExGram.Model.InputMediaDocument
      }[type]

    struct!(module, media)
  end

  defp markdown_parse_error?(%ExGram.Error{code: 400, message: message}) when is_binary(message),
    do: String.contains?(message, "can't parse entities")

  defp markdown_parse_error?(_), do: false
end
