defmodule ExironWeb.Schemas.AuthResponse do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias ExironWeb.Schemas.SchemaHelpers
  require OpenApiSpex
  @version_file Path.expand("../../../VERSION", __DIR__)
  @external_resource @version_file

  OpenApiSpex.schema(%{
    title: "AuthResponse",
    type: :object,
    required: [
      :auth_response,
      :hook,
      :msgtype,
      :server_version,
      :protocol_version,
      :capabilities
    ],
    properties: %{
      auth_response: %Schema{type: :string, enum: ["OK"]},
      hook: %Schema{type: :string},
      msgtype: %Schema{type: :string, enum: ["auth"]},
      server_version: %Schema{type: :string},
      protocol_version: %Schema{type: :string},
      capabilities: SchemaHelpers.capabilities()
    },
    example: %{
      auth_response: "OK",
      hook: "assistant",
      msgtype: "auth",
      server_version: Mix.Project.config()[:version],
      protocol_version: Exiron.Protocol.protocol_version(),
      capabilities: ["http_auth", "websocket"]
    }
  })
end
