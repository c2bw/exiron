defmodule ExironWeb.Plugs.ApiAuthentication do
  @moduledoc false

  import Plug.Conn, only: [assign: 3, halt: 1]

  alias Exiron.Hub
  alias Exiron.Hub.AuthenticatedHook
  alias ExironWeb.ExironController.{ErrorResponse, Request}

  @assign :api_authentication

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- Request.require_bearer(conn),
         {:ok, %{hook: hook}} <- Hub.authenticate(token) do
      assign(conn, @assign, AuthenticatedHook.new(hook))
    else
      {:error, reason} ->
        conn
        |> ErrorResponse.render(reason)
        |> halt()
    end
  end
end
