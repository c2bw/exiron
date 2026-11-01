defmodule ExironWeb.Schemas.AuthRequest do
  @moduledoc false

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AuthRequest",
    type: :object,
    properties: %{
      hook_token: %Schema{type: :string}
    },
    example: %{hook_token: "replace-with-a-random-hook-token"}
  })
end
