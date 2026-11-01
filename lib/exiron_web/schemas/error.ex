defmodule ExironWeb.Schemas.Error do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias Exiron.Protocol
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Error",
    type: :object,
    required: [:code, :error],
    properties: %{
      code: %Schema{type: :string, enum: Protocol.error_codes()},
      error: %Schema{type: :string},
      delivery: ExironWeb.Schemas.DeliveryDiagnostics,
      retry_after_ms: %Schema{type: :integer, nullable: true}
    },
    example: %{
      code: "hook_already_connected",
      error: "hook already connected",
      delivery: ExironWeb.Schemas.DeliveryDiagnostics,
      retry_after_ms: 3000
    }
  })
end
