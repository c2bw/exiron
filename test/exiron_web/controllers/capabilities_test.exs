defmodule ExironWeb.CapabilitiesTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok = Hub.configure(Exiron.HubCase.load_router!(), Telegram.new([]))
    :ok
  end

  test "discovery is authenticated and leaves queues, leases, and traces unchanged", %{conn: conn} do
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hi"))
    before = :sys.get_state(Hub)
    response = conn |> auth() |> get("/api/capabilities")

    assert json_response(response, 200) == %{
             "protocol_version" => Exiron.Protocol.protocol_version(),
             "capabilities" => Exiron.Protocol.capabilities()
           }

    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert :sys.get_state(Hub) == before
    assert get(conn, "/api/capabilities") |> json_response(401)

    assert conn
           |> put_req_header("authorization", "Bearer wrong-token")
           |> get("/api/capabilities")
           |> json_response(401)
  end

  test "24 startup lookups work even when the legacy authentication budget is exhausted", %{
    conn: conn
  } do
    # Populate the surrounding windows too, so this remains valid across a clock tick.
    now = System.system_time(:second)

    for second <- (now - 1)..(now + 2) do
      :ets.insert(:rate_limit_entries, {{:api_authentication, "127.0.0.1", second}, 10})
    end

    on_exit(fn -> :ets.delete_all_objects(:rate_limit_entries) end)

    for _ <- 1..24 do
      assert conn |> auth() |> get("/api/capabilities") |> json_response(200)
    end

    assert post(conn, "/api/auth", %{hook_token: "ai-token"}) |> json_response(429)
    assert :sys.get_state(Hub).delivery.clients == %{}
  end

  test "discovery keeps the ordinary bearer API rate limits", %{conn: conn} do
    now = System.system_time(:second)
    identity = "bearer:" <> Base.url_encode64(:crypto.hash(:sha256, "ai-token"), padding: false)
    :ets.insert(:rate_limit_entries, {{:api_token, identity, now}, 1200})
    on_exit(fn -> :ets.delete_all_objects(:rate_limit_entries) end)
    assert conn |> auth() |> get("/api/capabilities") |> json_response(429)
  end

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer ai-token")
end
