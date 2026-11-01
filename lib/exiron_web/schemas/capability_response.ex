defmodule ExironWeb.Schemas.CapabilityResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  alias ExironWeb.Schemas.SchemaHelpers
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CapabilityResponse",
    type: :object,
    required: [:protocol_version, :capabilities],
    properties: %{
      protocol_version: %Schema{type: :string, minLength: 1},
      capabilities: SchemaHelpers.capabilities()
    }
  })
end
