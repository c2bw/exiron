defmodule ExironWeb.MetricsController do
  use ExironWeb, :controller

  def show(conn, _params) do
    token = Application.get_env(:exiron, :metrics_token)
    authorization = get_req_header(conn, "authorization")

    cond do
      not is_binary(token) or token == "" ->
        send_resp(conn, 404, "Not found\n")

      not authorized?(authorization, token) ->
        conn |> put_resp_header("www-authenticate", "Bearer") |> send_resp(401, "Unauthorized\n")

      true ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
        |> send_resp(200, Exiron.Metrics.scrape())
    end
  end

  defp authorized?(["Bearer " <> candidate], token),
    do: Plug.Crypto.secure_compare(candidate, token)

  defp authorized?(_headers, _token), do: false
end
