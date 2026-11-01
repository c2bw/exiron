defmodule ExironWeb.Schemas.SendFailure do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "SendFailure",
    type: :object,
    required: [
      :id,
      :at,
      :operation,
      :hook,
      :chat_id,
      :bot_name,
      :datatype,
      :preview,
      :reason
    ],
    properties: %{
      id: %Schema{type: :string},
      at: SchemaHelpers.date_time(),
      operation: %Schema{type: :string, enum: ["reply", "push"]},
      hook: %Schema{type: :string},
      chat_id: %Schema{type: :integer},
      bot_name: SchemaHelpers.nullable_string(),
      datatype: SchemaHelpers.datatype(),
      preview: %Schema{type: :string},
      reason: %Schema{type: :string},
      delivery: ExironWeb.Schemas.DeliveryDiagnostics
    }
  })
end
