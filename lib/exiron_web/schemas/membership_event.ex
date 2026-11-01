defmodule ExironWeb.Schemas.MembershipEvent do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MembershipEvent",
    type: :object,
    required: [
      :id,
      :at,
      :action,
      :chat_id,
      :chat_title,
      :bot_name,
      :bot_user_id,
      :old_status,
      :new_status
    ],
    properties: %{
      id: %Schema{type: :string},
      at: SchemaHelpers.date_time(),
      action: %Schema{type: :string, enum: ["added", "removed"]},
      chat_id: %Schema{type: :integer},
      chat_title: SchemaHelpers.nullable_string(),
      bot_name: SchemaHelpers.nullable_string(),
      bot_user_id: SchemaHelpers.nullable_integer(),
      old_status: SchemaHelpers.nullable_string(),
      new_status: SchemaHelpers.nullable_string()
    }
  })
end
