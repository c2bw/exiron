defmodule ExironWeb.Schemas.ClientPresence do
  @moduledoc false
  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ClientPresence",
    type: :object,
    description:
      "Observed contact for the current or last client of a hook. Assigned work is not proof that a handler is executing; HTTP clients can pause polling while processing.",
    properties: %{
      runtime: ExironWeb.Schemas.ClientRuntimeObservation,
      client_sdk: %Schema{type: :string, nullable: true, enum: ["go", "elixir"]},
      client_version: %Schema{
        type: :string,
        nullable: true,
        maxLength: 64,
        description: "Self-reported SDK package version; not the wire protocol version."
      },
      client_id: SchemaHelpers.nullable_string(),
      current_client_id: SchemaHelpers.nullable_string(),
      transport: %Schema{type: :string, nullable: true, enum: ["http", "websocket"]},
      state: %Schema{
        type: :string,
        enum: [
          "never_seen",
          "http_polling",
          "http_lease_expired",
          "websocket_connected",
          "websocket_disconnected",
          "different_client",
          "unassigned"
        ]
      },
      last_contact_at: SchemaHelpers.nullable_date_time(),
      last_contact_kind: SchemaHelpers.nullable_string(),
      disconnected_at: SchemaHelpers.nullable_date_time(),
      awaiting_response: %Schema{type: :integer, minimum: 0},
      sending_requests: %Schema{type: :integer, minimum: 0},
      other_assigned_requests: %Schema{type: :integer, minimum: 0}
    }
  })
end
