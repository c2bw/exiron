defmodule ExironWeb.Schemas.CancelPayload do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CancelPayload",
    type: :object,
    required: [:req_id],
    properties: %{req_id: %Schema{type: :string, minLength: 1, maxLength: 128}}
  })
end
