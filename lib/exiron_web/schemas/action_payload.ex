defmodule ExironWeb.Schemas.ActionPayload do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ActionPayload",
    type: :object,
    required: [:req_id, :action],
    properties: %{
      req_id: %Schema{type: :string},
      action: %Schema{type: :string, enum: Exiron.Hub.MessageMetadata.actions()}
    }
  })
end
