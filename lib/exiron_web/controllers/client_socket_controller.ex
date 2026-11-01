defmodule ExironWeb.ClientSocketController do
  use ExironWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Exiron.Hub
  alias Exiron.Hub.AuthenticatedHook
  alias ExironWeb.ExironController.{ErrorResponse, Request}
  alias ExironWeb.ClientSocket
  alias ExironWeb.Schemas
  alias OpenApiSpex.Schema

  tags(["Exiron"])

  operation(:connect,
    summary: "Connect a managed client websocket",
    description:
      "Upgrades to the Exiron websocket protocol. After a successful upgrade, protocol errors are sent as websocket close frames with a JSON error frame.",
    parameters: [
      "x-exiron-sdk": [
        in: :header,
        type: :string,
        required: false,
        description: "Optional self-reported SDK: go or elixir. Display metadata only."
      ],
      "x-exiron-sdk-version": [
        in: :header,
        schema: %Schema{type: :string, maxLength: 64},
        required: false,
        description: "Optional SDK package SemVer, independent of the wire protocol."
      ],
      client_id: [
        in: :query,
        type: :string,
        required: true,
        description: "Stable identifier for this client instance"
      ],
      listen: [
        in: :query,
        schema: %Schema{type: :string, enum: ["false", "true", "all"]},
        required: false,
        description:
          "Use true for listen-style Telegram messages, or all to also receive routed matches as listen messages"
      ]
    ],
    security: [%{"bearerAuth" => []}],
    responses: [
      switching_protocols: "WebSocket upgrade accepted",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      too_many_requests: {"Rate limit exceeded", "application/json", Schemas.Error},
      service_unavailable: {"Hub disabled", "application/json", Schemas.Error}
    ]
  )

  def connect(conn, params) do
    with {:ok, credential} <- socket_credential(conn) do
      WebSockAdapter.upgrade(
        conn,
        ClientSocket,
        %{
          credential: credential,
          client_id: params["client_id"],
          client_identity: Request.client_identity(conn),
          listen: Request.listen_mode(params["listen"])
        },
        timeout: :infinity
      )
    else
      {:error, reason} -> ErrorResponse.render(conn, reason)
    end
  end

  defp socket_credential(conn) do
    case Request.authenticated_credential(conn) do
      {:ok, %AuthenticatedHook{} = authentication} ->
        {:ok, authentication}

      {:ok, token} ->
        with {:ok, %{hook: hook}} <- Hub.authenticate(token) do
          {:ok, AuthenticatedHook.new(hook)}
        end

      error ->
        error
    end
  end
end
