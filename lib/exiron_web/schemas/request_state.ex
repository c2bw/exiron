defmodule ExironWeb.Schemas.RequestState do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RequestState",
    type: :object,
    required: [:req_id, :state, :expires_in_ms],
    properties: %{
      req_id: %Schema{type: :string},
      state: %Schema{
        type: :string,
        enum: ["active", "cancelled", "expired", "completed", "closed"]
      },
      expires_in_ms: %Schema{type: :integer, minimum: 0, nullable: true}
    }
  })
end
