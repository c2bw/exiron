defmodule ExironWeb.Schemas.WebSocketConnected do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "WebSocketConnected",
    type: :object,
    required: [
      :type,
      :hook,
      :client_id,
      :listen,
      :server_version,
      :protocol_version,
      :capabilities
    ],
    properties: %{
      runtime_ref: %Schema{type: :string, nullable: true, minLength: 1, maxLength: 128},
      type: %Schema{type: :string, enum: ["connected"]},
      hook: %Schema{type: :string},
      client_id: %Schema{type: :string},
      listen: %Schema{
        oneOf: [
          %Schema{type: :boolean},
          %Schema{type: :string, enum: ["all"]}
        ]
      },
      server_version: %Schema{type: :string},
      protocol_version: %Schema{type: :string},
      capabilities: SchemaHelpers.capabilities()
    }
  })
end
