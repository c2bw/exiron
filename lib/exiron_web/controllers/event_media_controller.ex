defmodule ExironWeb.EventMediaController do
  use ExironWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Exiron.Hub
  alias Exiron.Hub.EventMediaStore
  alias ExironWeb.Auth
  alias ExironWeb.ExironController.{ErrorResponse, Request}
  alias OpenApiSpex.Schema

  operation(:show,
    summary: "Retrieve an authenticated event image preview",
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Opaque media identifier"]
    ],
    security: [%{"dashboardSession" => []}, %{"bearerAuth" => []}],
    responses: [
      ok: {"Image preview", "image/*", %Schema{type: :string, format: :binary}},
      unauthorized: {"Unauthorized", "application/json", ExironWeb.Schemas.Error},
      not_found: {"Media not found", "text/plain", %Schema{type: :string}}
    ]
  )

  def show(conn, %{"id" => id}) do
    with {:ok, scope} <- authorized_scope(conn),
         {:ok, %{mime_type: mime_type, bytes: bytes}} <- EventMediaStore.fetch(id, scope) do
      conn
      |> put_resp_content_type(mime_type)
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(:ok, bytes)
    else
      {:error, :not_found} -> send_resp(conn, :not_found, "")
      {:error, reason} -> ErrorResponse.render(conn, reason)
    end
  end

  defp authorized_scope(conn) do
    if Auth.authenticated?(conn) do
      {:ok, :dashboard}
    else
      with {:ok, token} <- Request.require_bearer(conn),
           {:ok, %{hook: hook}} <- Hub.authenticate(token) do
        {:ok, {:hook, hook}}
      end
    end
  end
end
