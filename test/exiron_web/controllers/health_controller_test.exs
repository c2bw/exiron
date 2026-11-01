defmodule ExironWeb.HealthControllerTest do
  use ExironWeb.ConnCase, async: false

  alias Exiron.Hub

  setup do
    previous = :sys.get_state(Hub)
    on_exit(fn -> :sys.replace_state(Hub, fn _ -> previous end) end)
    :ok
  end

  test "liveness is public and independent of a disabled Hub", %{conn: conn} do
    :sys.replace_state(Hub, fn _ -> Exiron.Hub.State.new() end)
    response = get(conn, "/health/live")
    assert json_response(response, 200) == %{"status" => "alive"}
    assert get_resp_header(response, "cache-control") == ["no-store"]

    assert json_response(get(conn, "/health/ready"), 503) ==
             %{"status" => "not_ready", "reason" => "disabled"}
  end

  test "readiness distinguishes failed boot from an initialized Hub", %{conn: conn} do
    :sys.replace_state(Hub, fn _ -> Exiron.Hub.State.new(boot_failed?: true) end)
    assert json_response(get(conn, "/health/ready"), 503)["reason"] == "boot_failed"
    router = Exiron.HubCase.load_router!()
    :ok = Hub.configure(router, Exiron.Hub.Telegram.new([]))

    assert json_response(get(conn, "/health/ready"), 200) ==
             %{"status" => "ready", "reason" => "initialized"}
  end

  test "liveness stays responsive and readiness fails when the Hub is unresponsive", %{conn: conn} do
    :sys.suspend(Hub)

    try do
      assert json_response(get(conn, "/health/live"), 200)["status"] == "alive"
      assert json_response(get(conn, "/health/ready"), 503)["reason"] == "hub_unavailable"
    after
      :sys.resume(Hub)
    end
  end
end
