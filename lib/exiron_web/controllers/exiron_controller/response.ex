defmodule ExironWeb.ExironController.Response do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]

  alias ExironWeb.ExironController.ErrorResponse
  alias Exiron.Protocol

  def render_result(conn, :ok), do: json(conn, %{ok: true})
  def render_result(conn, {:ok, payload}), do: json(conn, payload)
  def render_result(conn, {:error, reason}), do: ErrorResponse.render(conn, reason)

  def auth_payload(result), do: Protocol.auth_payload(result)
end
