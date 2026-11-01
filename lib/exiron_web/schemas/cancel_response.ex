defmodule ExironWeb.Schemas.CancelResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CancelResponse",
    type: :object,
    required: [:ok, :cancelled, :delivery_status, :message_ids],
    properties: %{
      ok: %Schema{type: :boolean},
      cancelled: %Schema{type: :boolean},
      delivery_status: %Schema{type: :string, enum: ["not_started", "partial", "unknown"]},
      message_ids: %Schema{type: :array, items: %Schema{type: :integer}}
    }
  })
end
