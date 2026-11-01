defmodule ExironWeb.ClientVersionTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub

  setup do
    :ok = Hub.configure(Exiron.HubCase.load_router!())
    :ok
  end

  test "poll headers appear in the API and every hook view without runtime reports", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> put_req_header("x-exiron-sdk", "go")
      |> put_req_header("x-exiron-sdk-version", "0.5.7")
      |> get("/api/requests?client_id=versioned&delivery_mode=explicit")

    assert json_response(conn, 200)["requests"] == []

    status =
      build_conn()
      |> put_req_header("authorization", "Bearer ai-token")
      |> get("/api/status")
      |> json_response(200)

    assert hd(status["hooks"])["client"]["client_version"] == "0.5.7"

    for {path, selector} <- [
          {"/", "#exiron-hook-assistant-version"},
          {"/monitor", "#delivery-hook-assistant-client-version"},
          {"/hooks/assistant", "#hook-client-version"}
        ] do
      {:ok, view, _} = live(log_in(build_conn()), path)
      assert has_element?(view, selector, "Go SDK · 0.5.7")
    end
  end

  test "legacy clients display an honest unknown version", %{conn: conn} do
    {:ok, []} = Hub.poll("ai-token", client_id: "legacy")
    {:ok, view, _} = live(log_in(conn), "/hooks/assistant")
    assert has_element?(view, "#hook-client-version", "Version not reported")
  end
end
