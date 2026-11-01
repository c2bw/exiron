defmodule ExironWeb.Schemas.ClientEvent do
  @moduledoc false

  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ClientEvent",
    type: :object,
    required: [:id, :at, :action, :hook, :client_id, :listening],
    properties: %{
      id: %Schema{type: :string},
      at: SchemaHelpers.date_time(),
      action: %Schema{type: :string, enum: ["connected", "disconnected"]},
      hook: %Schema{type: :string},
      client_id: %Schema{type: :string},
      listening: %Schema{type: :boolean}
    }
  })
end
