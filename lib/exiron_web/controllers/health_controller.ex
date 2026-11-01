defmodule ExironWeb.HealthController do
  use ExironWeb, :controller

  def live(conn, _params), do: conn |> private_response() |> json(%{status: "alive"})

  def ready(conn, _params) do
    result =
      try do
        Exiron.Hub.readiness()
      catch
        :exit, _ -> %{ready: false, reason: :hub_unavailable}
      end

    conn
    |> private_response()
    |> put_status(if(result.ready, do: 200, else: 503))
    |> json(%{status: if(result.ready, do: "ready", else: "not_ready"), reason: result.reason})
  end

  defp private_response(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
