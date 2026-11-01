defmodule ExironWeb.Schemas.ClientRuntimeReport do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ClientRuntimeReport",
    type: :object,
    additionalProperties: false,
    required: [
      :client_id,
      :runtime_ref,
      :sequence,
      :phase,
      :active_handlers,
      :overdue_handlers,
      :quarantined_messages,
      :quarantine_bytes,
      :quarantine_enabled,
      :quarantine_available
    ],
    properties: %{
      client_id: %Schema{type: :string, minLength: 1, maxLength: 128},
      runtime_ref: %Schema{type: :string, minLength: 1, maxLength: 128},
      sequence: %Schema{type: :integer, minimum: 1, maximum: 9_007_199_254_740_991},
      phase: %Schema{
        type: :string,
        enum: ~w(idle connecting polling handling waiting backing_off draining stopped)
      },
      active_handlers: %Schema{type: :integer, minimum: 0, maximum: 64},
      overdue_handlers: %Schema{type: :integer, minimum: 0, maximum: 64},
      quarantined_messages: %Schema{type: :integer, minimum: 0, maximum: 1_000_000_000},
      quarantine_bytes: %Schema{type: :integer, minimum: 0, maximum: 1_099_511_627_776},
      quarantine_enabled: %Schema{type: :boolean},
      quarantine_available: %Schema{type: :boolean}
    }
  })
end
