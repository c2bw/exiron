defmodule ExironWeb.Schemas.PushResponse do
  @moduledoc false

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PushResponse",
    type: :object,
    required: [:ok, :sent],
    properties: %{
      ok: %Schema{type: :boolean},
      sent: %Schema{type: :integer, minimum: 0}
    },
    example: %{ok: true, sent: 1}
  })
end
