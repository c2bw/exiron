defmodule ExironWeb.MetricsControllerTest do
  use ExironWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:exiron, :metrics_token)
    on_exit(fn -> Application.put_env(:exiron, :metrics_token, original) end)
    :ok
  end

  test "metrics are disabled without a dedicated token", %{conn: conn} do
    Application.put_env(:exiron, :metrics_token, nil)
    assert conn |> get(~p"/metrics") |> response(404) == "Not found\n"
  end

  test "requires the dedicated bearer token and exports valid content type", %{conn: conn} do
    Application.put_env(:exiron, :metrics_token, "metrics-test-secret")
    assert conn |> get(~p"/metrics") |> response(401) == "Unauthorized\n"

    assert conn
           |> put_req_header("authorization", "Bearer wrong")
           |> get(~p"/metrics")
           |> response(401) == "Unauthorized\n"

    conn =
      conn |> put_req_header("authorization", "Bearer metrics-test-secret") |> get(~p"/metrics")

    assert response(conn, 200) =~ "exiron_response_duration_seconds_bucket"
    assert get_resp_header(conn, "content-type") == ["text/plain; version=0.0.4; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute response(conn, 200) =~ "metrics-test-secret"
  end

  test "unresponsive Hub does not hide VM metrics or return a successful Hub gauge", %{conn: conn} do
    Application.put_env(:exiron, :metrics_token, "metrics-test-secret")
    :sys.suspend(Exiron.Hub)

    try do
      conn =
        conn |> put_req_header("authorization", "Bearer metrics-test-secret") |> get(~p"/metrics")

      assert response(conn, 200) =~ "exiron_hub_snapshot_available 0\n"
      assert response(conn, 200) =~ "exiron_vm_memory_bytes "
      refute response(conn, 200) =~ "exiron_pending_requests "
    after
      :sys.resume(Exiron.Hub)
    end
  end
end
