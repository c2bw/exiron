defmodule ExironWeb.Schemas.WebSocketError do
  @moduledoc false

  alias Exiron.Protocol
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "WebSocketError",
    type: :object,
    required: [:type, :code, :error],
    properties: %{
      type: %Schema{type: :string, enum: ["error"]},
      code: %Schema{type: :string, enum: Protocol.error_codes()},
      error: %Schema{type: :string},
      retry_after_ms: %Schema{type: :integer, nullable: true}
    }
  })
end
