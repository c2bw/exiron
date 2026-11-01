defmodule ExironWeb.Schemas.SchemaHelpers do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias Exiron.Protocol

  def message_metadata do
    entity = %Schema{
      type: :object,
      required: [:type, :offset, :length],
      properties: %{
        type: %Schema{type: :string},
        offset: %Schema{type: :integer, minimum: 0},
        length: %Schema{type: :integer, minimum: 1},
        url: %Schema{type: :string},
        language: %Schema{type: :string},
        custom_emoji_id: %Schema{type: :string},
        unix_time: %Schema{type: :integer},
        date_time_format: %Schema{type: :string},
        user: ExironWeb.Schemas.TelegramUser
      }
    }

    entities = %Schema{type: :array, items: entity, maxItems: 100, nullable: true}

    %{
      inline_keyboard: %Schema{
        type: :array,
        maxItems: 20,
        nullable: true,
        items: %Schema{
          type: :array,
          minItems: 1,
          maxItems: 8,
          items: %Schema{
            type: :object,
            required: [:text],
            properties: %{
              text: %Schema{type: :string, minLength: 1, maxLength: 256},
              callback_data: %Schema{type: :string, minLength: 1, maxLength: 64},
              url: %Schema{type: :string, maxLength: 2048}
            }
          }
        }
      },
      message_thread_id: %Schema{type: :integer, minimum: 1, nullable: true},
      media_group_id: nullable_string(),
      caption_overflow: %Schema{
        type: :boolean,
        default: false,
        description:
          "For media and albums, opt in to following text messages when captions exceed 1024 rendered UTF-16 units. Album captions belong on individual members."
      },
      caption: nullable_string(),
      entities: entities,
      caption_entities: entities,
      file_name: nullable_string(),
      mime_type: nullable_string(),
      parse_mode: %Schema{
        type: :string,
        enum: ["plain", "Markdown", "MarkdownV2", "HTML"],
        nullable: true
      }
    }
  end

  def datatype, do: %Schema{type: :string, enum: Protocol.datatypes()}

  def capabilities,
    do: %Schema{type: :array, items: %Schema{type: :string, enum: Protocol.capabilities()}}

  def string_list, do: %Schema{type: :array, items: %Schema{type: :string}}
  def date_time, do: %Schema{type: :string, format: :"date-time"}
  def nullable_date_time, do: %Schema{type: :string, format: :"date-time", nullable: true}
  def nullable_string, do: %Schema{type: :string, nullable: true}
  def nullable_integer, do: %Schema{type: :integer, nullable: true}
end
