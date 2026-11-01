defmodule ExironWeb.Schemas.ChatStatus do
  @moduledoc false

  alias ExironWeb.Schemas.{BotMembership, SchemaHelpers}
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ChatStatus",
    type: :object,
    required: [
      :id,
      :aliases,
      :default_bot,
      :current_bot,
      :bot_memberships,
      :polling,
      :last_polled_at
    ],
    properties: %{
      id: %Schema{type: :integer},
      aliases: SchemaHelpers.string_list(),
      default_bot: SchemaHelpers.nullable_string(),
      current_bot: SchemaHelpers.nullable_string(),
      bot_memberships: %Schema{type: :array, items: BotMembership},
      polling: %Schema{type: :boolean},
      last_polled_at: SchemaHelpers.nullable_date_time()
    }
  })
end
