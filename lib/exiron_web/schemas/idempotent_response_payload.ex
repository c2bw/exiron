defmodule ExironWeb.Schemas.IdempotentResponsePayload do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex
  @base ExironWeb.Schemas.ResponsePayload.schema()
  OpenApiSpex.schema(%Schema{
    @base
    | title: "IdempotentResponsePayload",
      required: [:idempotency_key | @base.required],
      properties:
        Map.put(@base.properties, :idempotency_key, %Schema{
          type: :string,
          minLength: 1,
          maxLength: 128,
          pattern: "^[A-Za-z0-9._:-]+$"
        })
  })
end
