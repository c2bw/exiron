defmodule ExironWeb.Schemas.HookStatus do
  @moduledoc false

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "HookStatus",
    type: :object,
    required: [:name, :connected, :listening, :queued],
    properties: %{
      name: %Schema{type: :string},
      connected: %Schema{type: :boolean},
      listening: %Schema{type: :boolean},
      queued: %Schema{type: :integer, minimum: 0},
      client: ExironWeb.Schemas.ClientPresence,
      health: ExironWeb.Schemas.DeliveryHealth
    }
  })
end
