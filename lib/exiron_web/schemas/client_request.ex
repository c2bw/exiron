defmodule ExironWeb.Schemas.ClientRequest do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  alias ExironWeb.Schemas.TelegramUser
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ClientRequest",
    type: :object,
    required: [
      :msgtype,
      :service_id,
      :chat_id,
      :instance,
      :datatype,
      :data,
      :sticker_id,
      :sticker_emoji,
      :emoji_list,
      :message_id,
      :reply_to_message_id,
      :from
    ],
    properties:
      Map.merge(
        %{
          callback_query: %Schema{
            type: :object,
            nullable: true,
            required: [:id, :origin_req_id],
            properties: %{
              id: %Schema{type: :string},
              origin_req_id: SchemaHelpers.nullable_string()
            }
          },
          msgtype: %Schema{type: :string, enum: ["request", "listen"]},
          req_id: %Schema{
            type: :string,
            nullable: true,
            description: "Present for request messages; omitted for listen messages."
          },
          followup_req_id: %Schema{
            type: :string,
            nullable: true,
            description:
              "Immediate originating request for an inherited reply-based follow-up. Omitted for commands and listen copies. Not conversation history."
          },
          service_id: %Schema{type: :integer},
          chat_id: %Schema{type: :integer},
          instance: SchemaHelpers.nullable_string(),
          datatype: SchemaHelpers.datatype(),
          data: %Schema{type: :string, format: :byte},
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
          reply_to_message_id: SchemaHelpers.nullable_integer(),
          from: TelegramUser
        },
        SchemaHelpers.message_metadata()
      )
  })
end
