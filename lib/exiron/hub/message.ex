defmodule Exiron.Hub.Message do
  @moduledoc false

  @type t :: %__MODULE__{}

  @types ~w(text audio video image file sticker album)
  @emoji_groups [
    # laughter / joy
    [
      "\u{1F606}",
      "\u{1F923}",
      "\u{1F600}",
      "\u{1F602}",
      "\u{1F604}",
      "\u{1F603}",
      "\u{1F601}"
    ],

    # crying / sadness
    [
      "\u{1F622}",
      "\u{1F625}",
      "\u{1F62D}",
      "\u{1F61E}",
      "\u{1F641}",
      "\u{1F613}",
      "\u{1F61F}",
      "\u{1F614}"
    ],

    # love / affection
    ["\u{2764}\u{FE0F}", "\u{1F970}", "\u{1F60D}", "\u{1F618}", "\u{1F617}"],

    # anger / frustration
    ["\u{1F621}", "\u{1F620}", "\u{1F92C}", "\u{1F624}", "\u{1F612}"],

    # surprise / shock
    ["\u{1F62E}", "\u{1F632}", "\u{1F631}", "\u{1F633}", "\u{1F628}"],

    # fear / worry
    ["\u{1F628}", "\u{1F630}", "\u{1F631}", "\u{1F627}", "\u{1F613}", "\u{1F61F}"],

    # sleepy / tired
    ["\u{1F634}", "\u{1F62A}", "\u{1F971}", "\u{1F611}", "\u{1F614}"],

    # party / celebration
    ["\u{1F973}", "\u{1F389}", "\u{1F38A}", "\u{1F64C}", "\u{2728}"],

    # approval / gratitude
    ["\u{1F44D}", "\u{1F44C}", "\u{1F64C}", "\u{2705}", "\u{1F64F}", "\u{1F44F}", "\u{1F970}"],

    # intensity / hype
    ["\u{1F525}", "\u{1F4AF}", "\u{26A1}", "\u{2728}", "\u{2705}", "\u{1F44D}"]
  ]

  @emoji_lists @emoji_groups
               |> Enum.map(&Enum.uniq/1)
               |> Enum.flat_map(fn group ->
                 Enum.map(group, &{&1, group})
               end)
               |> Map.new()

  @derive {Inspect,
           only: [
             :service_id,
             :chat_id,
             :bot_name,
             :datatype,
             :sticker_id,
             :file_unique_id,
             :sticker_emoji,
             :message_id,
             :reply_to_message_id,
             :from
           ]}
  defstruct [
    :service_id,
    :chat_id,
    :instance,
    :wire_instance,
    :bot_token,
    :bot_name,
    :datatype,
    :data,
    :sticker_id,
    :file_unique_id,
    :sticker_emoji,
    :message_id,
    :reply_to_message_id,
    :followup_req_id,
    :from,
    :message_thread_id,
    :media_group_id,
    :caption,
    :entities,
    :caption_entities,
    :file_name,
    :mime_type,
    :parse_mode,
    :edit_message_id,
    :inline_keyboard,
    :callback_buttons,
    :callback_query,
    :command_prompt,
    :guided_prompt_key,
    force_reply?: false,
    caption_overflow?: false,
    media_items: nil,
    media_message_ids: [],
    delivery_group: 0,
    delivery_index: 1,
    text_message_ids: [],
    final?: true
  ]

  def new(service_id, chat_id, datatype, data, instance \\ nil, opts \\ [])
      when datatype in ["keyboard", "callback" | @types] and is_binary(data) do
    %__MODULE__{
      service_id: service_id,
      chat_id: chat_id,
      instance: instance,
      wire_instance: Keyword.get(opts, :wire_instance),
      bot_token: Keyword.get(opts, :bot_token, instance),
      bot_name: Keyword.get(opts, :bot_name),
      datatype: datatype,
      data: data,
      sticker_id: Keyword.get(opts, :sticker_id),
      file_unique_id: Keyword.get(opts, :file_unique_id),
      sticker_emoji: Keyword.get(opts, :sticker_emoji),
      message_id: Keyword.get(opts, :message_id),
      reply_to_message_id: Keyword.get(opts, :reply_to_message_id),
      from: Keyword.get(opts, :from),
      message_thread_id: Keyword.get(opts, :message_thread_id),
      media_group_id: Keyword.get(opts, :media_group_id),
      caption: Keyword.get(opts, :caption),
      caption_overflow?: Keyword.get(opts, :caption_overflow, false),
      entities: Keyword.get(opts, :entities),
      caption_entities: Keyword.get(opts, :caption_entities),
      file_name: Keyword.get(opts, :file_name),
      mime_type: Keyword.get(opts, :mime_type),
      parse_mode: Keyword.get(opts, :parse_mode),
      edit_message_id: Keyword.get(opts, :edit_message_id),
      inline_keyboard: Keyword.get(opts, :inline_keyboard),
      callback_query: Keyword.get(opts, :callback_query),
      text_message_ids: Keyword.get(opts, :text_message_ids, []),
      final?: Keyword.get(opts, :final, true)
    }
  end

  @doc "Build an inbound service message with separately named identity fields."
  def incoming(service_id, chat_id, datatype, data, opts \\ []) do
    bot_token = Keyword.get(opts, :bot_token)
    bot_name = Keyword.get(opts, :bot_name)

    new(
      service_id,
      chat_id,
      datatype,
      data,
      bot_token,
      Keyword.merge(opts, wire_instance: Keyword.get(opts, :wire_instance, bot_name))
    )
  end

  @doc "Build an outbound service message with an explicit bot token and bot name."
  def outgoing(service_id, chat_id, datatype, data, bot_token, opts \\ []) do
    bot_name = Keyword.get(opts, :bot_name)

    new(
      service_id,
      chat_id,
      datatype,
      data,
      bot_token,
      Keyword.merge(opts,
        bot_token: bot_token,
        wire_instance: Keyword.get(opts, :wire_instance, bot_name)
      )
    )
  end

  def valid_type?(type), do: type in @types

  def payload_size(%__MODULE__{data: data}) when is_binary(data), do: byte_size(data)
  def payload_size(_message), do: 0

  def queued_payload_size(%__MODULE__{data: data}) when is_binary(data),
    do: div(byte_size(data) + 2, 3) * 4

  def queued_payload_size(_message), do: 0

  def text(%__MODULE__{datatype: "text", data: data}), do: data
  def text(%__MODULE__{caption: caption}) when is_binary(caption), do: caption
  def text(_message), do: ""

  def address(%__MODULE__{} = message) do
    %{
      service_id: message.service_id,
      chat_id: message.chat_id,
      instance: message.instance,
      bot_token: message.bot_token
    }
  end

  def base_address(address), do: %{address | instance: nil, bot_token: nil}

  def to_client(%__MODULE__{} = message, request_id) do
    message
    |> client_payload("request")
    |> Map.put(:req_id, request_id)
    |> then(fn payload ->
      if is_binary(message.followup_req_id),
        do: Map.put(payload, :followup_req_id, message.followup_req_id),
        else: payload
    end)
  end

  def to_listen(%__MODULE__{} = message), do: client_payload(message, "listen")

  defp client_payload(%__MODULE__{} = message, msgtype) do
    %{
      msgtype: msgtype,
      service_id: message.service_id,
      chat_id: message.chat_id,
      instance: message.wire_instance || message.bot_name,
      datatype: message.datatype,
      data: Base.encode64(message.data),
      sticker_id: message.sticker_id,
      file_unique_id: message.file_unique_id,
      sticker_emoji: message.sticker_emoji,
      emoji_list: emoji_list(message.sticker_emoji),
      message_id: message.message_id,
      reply_to_message_id: message.reply_to_message_id,
      from: message.from
    }
    |> Map.merge(Exiron.Hub.MessageMetadata.wire(message))
  end

  def client_payload_size(%{data: data}) when is_binary(data), do: byte_size(data)
  def client_payload_size(_payload), do: 0

  def emoji_list(emoji), do: emoji_group(emoji)

  def emoji_group(emoji) when is_binary(emoji), do: Map.get(@emoji_lists, emoji, [])
  def emoji_group(_emoji), do: []
end
