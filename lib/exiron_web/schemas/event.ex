defmodule ExironWeb.Schemas.Event do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Event",
    type: :object,
    required: [
      :id,
      :at,
      :direction,
      :target,
      :kind,
      :service_id,
      :chat_id,
      :bot_name,
      :datatype,
      :preview,
      :image_src,
      :sticker_id,
      :sticker_emoji,
      :emoji_list,
      :message_id,
      :reply_to_message_id
    ],
    properties: %{
      id: %Schema{type: :string},
      at: SchemaHelpers.date_time(),
      direction: %Schema{type: :string, enum: ["incoming", "outgoing"]},
      target: %Schema{type: :string},
      hook: SchemaHelpers.nullable_string(),
      kind: %Schema{type: :string},
      service_id: %Schema{type: :integer},
      chat_id: %Schema{type: :integer},
      bot_name: SchemaHelpers.nullable_string(),
      datatype: SchemaHelpers.datatype(),
      preview: %Schema{type: :string},
      image_src: SchemaHelpers.nullable_string(),
      sticker_id: SchemaHelpers.nullable_string(),
      file_unique_id: %Schema{
        type: :string,
        nullable: true,
        description:
          "Optional Telegram file identity for sticker deduplication; cannot be used to download or send a file. sticker_id remains the sendable file_id."
      },
      sticker_emoji: SchemaHelpers.nullable_string(),
      emoji_list: SchemaHelpers.string_list(),
      message_id: SchemaHelpers.nullable_integer(),
      reply_to_message_id: SchemaHelpers.nullable_integer()
    }
  })
end
