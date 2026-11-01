defmodule ExironWeb.BearerToken do
  @moduledoc """
  Parses the bearer credential accepted at the HTTP boundary.

  Keeping header parsing in one place ensures authentication and bearer-based
  rate limits identify requests with the same trimmed token.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      header when is_binary(header) -> parse(header)
      nil -> nil
    end
  end

  defp parse(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer", do: String.trim(token)

      _header ->
        nil
    end
  end
end
