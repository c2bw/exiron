defmodule Exiron.Hub.MessageMetadata do
  @moduledoc false

  @fields [
    :message_thread_id,
    :media_group_id,
    :callback_query,
    :caption,
    :entities,
    :caption_entities,
    :file_name,
    :mime_type
  ]
  @entity_keys [
    :type,
    :offset,
    :length,
    :url,
    :user,
    :language,
    :custom_emoji_id,
    :unix_time,
    :date_time_format
  ]
  @user_keys [:id, :is_bot, :first_name, :last_name, :username, :language_code]

  def actions,
    do:
      ~w(typing upload_photo record_video upload_video record_voice upload_voice upload_document choose_sticker find_location record_video_note upload_video_note)

  def fields, do: @fields

  def wire(message),
    do: message |> Map.take(@fields) |> Map.reject(fn {_key, value} -> is_nil(value) end)

  def validate(datatype, data, opts) do
    text = if datatype == "text", do: data, else: Keyword.get(opts, :caption) || ""

    if (datatype != "text" or Exiron.Hub.Telegram.TextSplitter.valid?(data)) and
         valid_string?(Keyword.get(opts, :caption), Exiron.Hub.Telegram.TextSplitter.max_bytes()) and
         valid_string?(Keyword.get(opts, :file_name), 255) and
         valid_string?(Keyword.get(opts, :mime_type), 255) and
         valid_thread?(Keyword.get(opts, :message_thread_id)) and
         Keyword.get(opts, :parse_mode) in [nil, "plain", "Markdown", "MarkdownV2", "HTML"] and
         is_boolean(Keyword.get(opts, :caption_overflow, false)) and
         (not Keyword.get(opts, :caption_overflow, false) or
            datatype in ["image", "video", "audio", "file", "album"]) and
         is_boolean(Keyword.get(opts, :final, true)) and
         is_boolean(Keyword.get(opts, :edit_origin, false)) and
         is_boolean(Keyword.get(opts, :reply_to_original, false)) and
         Exiron.Hub.InlineKeyboard.valid?(datatype, Keyword.get(opts, :inline_keyboard)) and
         (datatype != "keyboard" or is_list(Keyword.get(opts, :inline_keyboard))) and
         entities_valid?(Keyword.get(opts, :entities), if(datatype == "text", do: text, else: "")) and
         entities_valid?(Keyword.get(opts, :caption_entities), Keyword.get(opts, :caption) || "") and
         safe_filename?(Keyword.get(opts, :file_name)) do
      :ok
    else
      {:error, :invalid_payload}
    end
  end

  def entities_valid?(nil, _text), do: true

  def entities_valid?(entities, text) when is_list(entities) and length(entities) <= 100 do
    boundaries = if String.valid?(text), do: utf16_boundaries(text), else: MapSet.new()

    String.valid?(text) and
      Enum.all?(entities, fn entity ->
        type = get(entity, :type)
        offset = get(entity, :offset)
        length = get(entity, :length)

        is_binary(type) and byte_size(type) in 1..64 and is_integer(offset) and offset >= 0 and
          is_integer(length) and length > 0 and MapSet.member?(boundaries, offset) and
          MapSet.member?(boundaries, offset + length) and
          (is_nil(get(entity, :unix_time)) or is_integer(get(entity, :unix_time))) and
          Enum.all?(
            [:url, :language, :custom_emoji_id, :date_time_format],
            &valid_string?(get(entity, &1), 4096)
          ) and
          valid_user?(get(entity, :user))
      end)
  end

  def entities_valid?(_, _), do: false

  def telegram_entities(nil), do: nil

  def telegram_entities(entities) do
    Enum.map(entity_maps(entities), fn entity ->
      entity =
        case entity[:user] do
          user when is_map(user) -> Map.put(entity, :user, struct!(ExGram.Model.User, user))
          _ -> entity
        end

      struct!(ExGram.Model.MessageEntity, entity)
    end)
  end

  def sanitize_entities(entities) when is_list(entities), do: entity_maps(entities)
  def sanitize_entities(_), do: nil

  defp entity_maps(entities) do
    Enum.map(entities, fn entity ->
      entity = Map.new(@entity_keys, &{&1, get(entity, &1)}) |> reject_nil()

      case entity[:user] do
        user when is_map(user) ->
          Map.put(entity, :user, Map.new(@user_keys, &{&1, get(user, &1)}) |> reject_nil())

        _ ->
          entity
      end
    end)
  end

  defp valid_user?(nil), do: true

  defp valid_user?(user) when is_map(user),
    do:
      is_integer(get(user, :id)) and is_binary(get(user, :first_name)) and
        is_boolean(get(user, :is_bot))

  defp valid_user?(_), do: false
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_, _), do: nil
  defp valid_string?(nil, _), do: true

  defp valid_string?(value, limit) when is_binary(value),
    do: String.valid?(value) and byte_size(value) <= limit

  defp valid_string?(_, _), do: false
  defp valid_thread?(nil), do: true
  defp valid_thread?(id), do: is_integer(id) and id > 0
  defp safe_filename?(nil), do: true

  defp safe_filename?(name) when is_binary(name),
    do: not String.contains?(name, ["\r", "\n", "/", "\\"])

  defp safe_filename?(_), do: false
  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  def valid_stream_text?(text), do: Exiron.Hub.Telegram.TextSplitter.valid?(text)

  defp utf16_boundaries(text) do
    {_offset, boundaries} =
      Enum.reduce(String.to_charlist(text), {0, MapSet.new([0])}, fn char, {offset, boundaries} ->
        next = offset + if(char > 0xFFFF, do: 2, else: 1)
        {next, MapSet.put(boundaries, next)}
      end)

    boundaries
  end
end
