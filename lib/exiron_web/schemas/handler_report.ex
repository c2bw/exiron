defmodule ExironWeb.Schemas.HandlerReport do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "HandlerReport",
    type: :object,
    additionalProperties: false,
    required: [:req_id, :client_id, :delivery_id, :attempt, :max_attempts, :state],
    properties: %{
      req_id: %Schema{type: :string, minLength: 1, maxLength: 128},
      client_id: %Schema{type: :string, minLength: 1, maxLength: 128},
      delivery_id: %Schema{type: :string, minLength: 1, maxLength: 128},
      attempt: %Schema{type: :integer, minimum: 1, maximum: 10},
      max_attempts: %Schema{type: :integer, minimum: 1, maximum: 10},
      state: %Schema{type: :string, enum: ["retrying", "exhausted", "recovered"]},
      category: %Schema{type: :string, enum: ["handler_error", "client_error", "exception"]}
    }
  })
end
