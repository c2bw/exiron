defmodule ExironWeb.Schemas.OkResponse do
  @moduledoc false

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OkResponse",
    type: :object,
    required: [:ok],
    properties: %{
      ok: %Schema{type: :boolean},
      final: %Schema{type: :boolean},
      message_ids: %Schema{type: :array, items: %Schema{type: :integer}, maxItems: 32},
      message_id: %Schema{type: :integer}
    },
    example: %{ok: true}
  })
end
