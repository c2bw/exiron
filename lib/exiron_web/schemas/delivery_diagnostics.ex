defmodule ExironWeb.Schemas.DeliveryDiagnostics do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  @error %Schema{
    type: :object,
    nullable: true,
    properties: %{
      category: %Schema{type: :string},
      message: %Schema{type: :string},
      code: %Schema{type: :integer, nullable: true},
      retry_after_ms: %Schema{type: :integer, nullable: true}
    }
  }
  @part %Schema{
    type: :object,
    required: [:id, :index, :ordinal, :chat_id, :operation, :status, :attempts, :message_ids],
    properties: %{
      id: %Schema{type: :string},
      index: %Schema{type: :integer},
      ordinal: %Schema{type: :integer},
      chat_id: %Schema{type: :integer},
      bot_name: %Schema{type: :string, nullable: true},
      operation: %Schema{type: :string, enum: ["send", "edit", "delete", "action"]},
      status: %Schema{
        type: :string,
        enum: ["queued", "in_flight", "confirmed", "rejected", "unknown"]
      },
      attempts: %Schema{type: :integer},
      message_id: %Schema{type: :integer, nullable: true},
      message_ids: %Schema{type: :array, items: %Schema{type: :integer}},
      error: @error
    }
  }
  OpenApiSpex.schema(%{
    title: "DeliveryDiagnostics",
    type: :object,
    required: [
      :id,
      :request_id,
      :operation,
      :outcome,
      :delivery_status,
      :attempts,
      :planned_parts,
      :confirmed_parts,
      :rejected_parts,
      :unknown_parts,
      :in_flight_parts,
      :unattempted_parts,
      :omitted_parts,
      :retry_available,
      :retry_safe,
      :retry_action,
      :last_error,
      :parts
    ],
    properties: %{
      id: %Schema{type: :string},
      request_id: %Schema{type: :string, nullable: true},
      operation: %Schema{type: :string},
      outcome: %Schema{
        type: :string,
        enum: ["sending", "succeeded", "failed", "timed_out", "cancelled", "expired"]
      },
      delivery_status: %Schema{
        type: :string,
        enum: ["not_started", "confirmed", "partial", "unknown"]
      },
      attempts: %Schema{type: :integer},
      planned_parts: %Schema{type: :integer},
      confirmed_parts: %Schema{type: :integer},
      rejected_parts: %Schema{type: :integer},
      unknown_parts: %Schema{type: :integer},
      in_flight_parts: %Schema{type: :integer},
      unattempted_parts: %Schema{type: :integer},
      omitted_parts: %Schema{type: :integer},
      retry_available: %Schema{type: :boolean},
      retry_safe: %Schema{type: :boolean},
      retry_action: %Schema{
        type: :string,
        enum: ["none", "wait", "retry_request", "fix_request", "inspect_chat", "request_closed"]
      },
      last_error: @error,
      parts: %Schema{type: :array, maxItems: 128, items: @part}
    }
  })
end
