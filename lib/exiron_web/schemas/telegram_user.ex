defmodule ExironWeb.Schemas.TelegramUser do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TelegramUser",
    type: :object,
    nullable: true,
    required: [:id, :is_bot, :first_name],
    properties: %{
      id: %Schema{type: :integer},
      is_bot: %Schema{type: :boolean},
      first_name: %Schema{type: :string},
      last_name: SchemaHelpers.nullable_string(),
      username: SchemaHelpers.nullable_string(),
      language_code: SchemaHelpers.nullable_string()
    }
  })
end
