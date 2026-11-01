defmodule ExironWeb.RequestDiagnosticController do
  use ExironWeb, :controller
  alias Exiron.Hub

  def show(conn, %{"id" => id}) do
    conn = conn |> put_resp_header("cache-control", "no-store")

    case Hub.request_trace(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Diagnostic is no longer retained."})

      trace ->
        conn
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="exiron-request-diagnostic.json")
        )
        |> json(Exiron.Hub.DiagnosticExport.build(trace))
    end
  end
end
