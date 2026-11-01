defmodule ExironWeb.Schemas.DeliveryHealth do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeliveryHealth",
    description:
      "In-memory counters since Hub start/reset, scoped to configured hooks. Failed send operations include partial failures and timeouts; successful response latency runs from acceptance through Telegram send completion.",
    type: :object,
    properties: %{
      queued: %Schema{type: :integer, minimum: 0},
      queued_bytes: %Schema{
        type: :integer,
        minimum: 0,
        description: "Queued payload bytes; excludes deliveries awaiting acknowledgement."
      },
      pending: %Schema{type: :integer, minimum: 0},
      in_flight_sends: %Schema{type: :integer, minimum: 0},
      in_flight_send_limit: %Schema{
        type: :integer,
        minimum: 1,
        description: "Effective send limit; present on individual hook health records."
      },
      send_capacity_rejections: %Schema{type: :integer, minimum: 0},
      in_flight_send_bytes: %Schema{
        type: :integer,
        minimum: 0,
        description:
          "Source payload and client option bytes retained by active sends, including coordinator waits."
      },
      in_flight_send_bytes_limit: %Schema{
        type: :integer,
        minimum: 1,
        description: "Effective per-hook active send byte limit."
      },
      send_byte_capacity_rejections: %Schema{type: :integer, minimum: 0},
      unavailable_rejections: %Schema{type: :integer, minimum: 0},
      overload_rejections: %Schema{type: :integer, minimum: 0},
      send_failures: %Schema{type: :integer, minimum: 0},
      completed_responses: %Schema{type: :integer, minimum: 0},
      response_duration_ms: %Schema{type: :number, minimum: 0},
      average_response_ms: %Schema{type: :number, minimum: 0, nullable: true},
      last_response_ms: %Schema{type: :number, minimum: 0, nullable: true},
      last_connected_at: SchemaHelpers.nullable_date_time(),
      last_disconnected_at: SchemaHelpers.nullable_date_time()
    }
  })
end
