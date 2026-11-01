defmodule ExironWeb.Schemas.RequestsResponse do
  @moduledoc false

  alias ExironWeb.Schemas.ClientRequest
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RequestsResponse",
    type: :object,
    required: [:requests],
    properties: %{
      runtime_ref: %Schema{type: :string, nullable: true, minLength: 1, maxLength: 128},
      delivery_id: %Schema{
        type: :string,
        nullable: true,
        description: "Present for explicit delivery mode when a batch must be acknowledged."
      },
      requests: %Schema{type: :array, items: ClientRequest}
    }
  })
end
