defmodule ExironWeb.Schemas.DataPayload do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DataPayload",
    type: :object,
    required: [:datatype, :data],
    properties:
      Map.merge(
        %{
          delivery_receipts: %Schema{
            type: :boolean,
            default: false,
            description: "Return Telegram-confirmed message IDs scoped to each service and chat."
          },
          datatype: SchemaHelpers.datatype(),
          data: %Schema{type: :string, format: :byte},
          sticker_emoji: %Schema{
            type: :string,
            nullable: true,
            description: "Optional emoji associated with a sticker payload."
          },
          bot: %Schema{
            type: :string,
            nullable: true,
            description: "Optional configured Telegram bot name to use for this push."
          },
          chat_id: %Schema{
            type: :integer,
            description: "Optional Telegram chat ID. Omit to push to every eligible routed chat."
          }
        },
        SchemaHelpers.message_metadata()
      ),
    example: %{datatype: "text", data: "aGVsbG8=", chat_id: -1_001_234_567_890}
  })
end
