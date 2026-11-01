defmodule ExironWeb.Schemas.ResponsePayload do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ResponsePayload",
    type: :object,
    required: [:req_id, :datatype, :data],
    properties:
      Map.merge(
        %{
          reply_to_original: %Schema{
            type: :boolean,
            default: false,
            description:
              "Opt in when starting a response: the first sent message replies to the original incoming message. Streams retain this choice. Not valid on completed edits or with edit_origin."
          },
          edit_origin: %Schema{
            type: :boolean,
            default: false,
            description:
              "Edit the message containing the clicked button. Only valid for callback requests."
          },
          req_id: %Schema{type: :string},
          final: %Schema{
            type: :boolean,
            default: true,
            description:
              "False updates a text reply without completing the request; true completes it."
          },
          datatype: SchemaHelpers.datatype(),
          data: %Schema{type: :string, format: :byte},
          sticker_emoji: %Schema{
            type: :string,
            nullable: true,
            description: "Optional emoji associated with a sticker payload."
          }
        },
        SchemaHelpers.message_metadata()
      ),
    example: %{req_id: "request-id", datatype: "text", data: "aGVsbG8="}
  })
end
