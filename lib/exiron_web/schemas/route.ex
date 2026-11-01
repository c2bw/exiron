defmodule ExironWeb.Schemas.Route do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Route",
    type: :object,
    required: [:id, :service_id, :chat_id, :chat_alias, :to, :messages, :push],
    properties: %{
      id: %Schema{type: :integer},
      service_id: %Schema{type: :integer},
      chat_id: %Schema{type: :integer},
      chat_alias: %Schema{type: :string},
      to: %Schema{type: :string},
      messages: SchemaHelpers.string_list(),
      passthrough: %Schema{type: :boolean},
      push: %Schema{type: :boolean},
      default_bot: SchemaHelpers.nullable_string()
    }
  })
end
