defmodule ExironWeb.Schemas.ClientRuntimeObservation do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ClientRuntimeObservation",
    type: :object,
    nullable: true,
    description:
      "Client-reported gauges, not proof of liveness or delivery. Server receipt time determines freshness.",
    properties: %{
      phase: %Schema{type: :string},
      active_handlers: %Schema{type: :integer, minimum: 0},
      overdue_handlers: %Schema{type: :integer, minimum: 0},
      quarantined_messages: %Schema{type: :integer, minimum: 0},
      quarantine_bytes: %Schema{type: :integer, minimum: 0},
      quarantine_enabled: %Schema{type: :boolean},
      quarantine_available: %Schema{type: :boolean},
      reported_at: %Schema{type: :string, format: :"date-time"},
      age_ms: %Schema{type: :integer, minimum: 0},
      stale_after_ms: %Schema{type: :integer, minimum: 1},
      stale: %Schema{type: :boolean},
      status: %Schema{type: :string, enum: ~w(fresh stale session_inactive)}
    }
  })
end
