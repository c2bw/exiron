defmodule ExironWeb.Schemas.BotMembership do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BotMembership",
    type: :object,
    required: [:chat_id, :bot_name, :bot_user_id, :status, :present],
    properties: %{
      chat_id: %Schema{type: :integer},
      bot_name: SchemaHelpers.nullable_string(),
      bot_user_id: SchemaHelpers.nullable_integer(),
      status: %Schema{type: :string},
      present: %Schema{type: :boolean},
      error: SchemaHelpers.nullable_string()
    }
  })
end
