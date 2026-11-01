defmodule ExironWeb.Schemas.ClientLeaseResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ClientLeaseResponse",
    type: :object,
    required: [:ok, :lease_timeout_ms],
    properties: %{
      ok: %Schema{type: :boolean},
      lease_timeout_ms: %Schema{type: :integer, minimum: 1}
    }
  })
end
