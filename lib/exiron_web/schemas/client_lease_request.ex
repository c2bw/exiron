defmodule ExironWeb.Schemas.ClientLeaseRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ClientLeaseRequest",
    type: :object,
    required: [:client_id, :delivery_id],
    properties: %{
      client_id: %Schema{type: :string, minLength: 1, maxLength: 128},
      delivery_id: %Schema{type: :string, minLength: 1, maxLength: 128}
    }
  })
end
