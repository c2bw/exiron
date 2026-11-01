defmodule ExironWeb.ClientLeaseTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{HookToken, Message, Telegram}

  setup do
    router = Exiron.HubCase.load_router!()
    router = %{router | hooks: Map.put(router.hooks, "other", HookToken.hash("other-token"))}

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:ok, %{message_id: 901}} end
        )
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hi", "bot-token"))

    {:ok, %{delivery_id: batch, requests: [request]}} =
      Hub.poll_delivery("ai-token", client_id: "worker", listen: true)

    %{batch: batch, id: request.req_id}
  end

  test "renews only the timer and contact without consuming or acknowledging work", %{
    conn: conn,
    batch: batch
  } do
    before = :sys.get_state(Hub)
    old = before.delivery.clients["assistant"]

    assert renew(conn, "worker", batch) |> json_response(200) == %{
             "ok" => true,
             "lease_timeout_ms" => before.settings.client_timeout
           }

    after_state = :sys.get_state(Hub)
    renewed = after_state.delivery.clients["assistant"]
    assert renewed.lease != old.lease
    assert renewed.http_delivery == old.http_delivery
    assert renewed.listen_mode == old.listen_mode
    assert renewed.connected_at == old.connected_at
    assert after_state.delivery.pending == before.delivery.pending
    assert after_state.delivery.queues == before.delivery.queues
    assert after_state.activity == before.activity
    assert after_state.delivery.client_presence["assistant"].last_contact_kind == "lease_renewal"
    send(Hub, {:expire_client, "assistant", "worker", old.lease})
    assert :sys.get_state(Hub).delivery.clients["assistant"].lease == renewed.lease
  end

  test "invalid, unauthorized and stale identities cannot renew", %{conn: conn, batch: batch} do
    assert renew(conn, "other-worker", batch) |> json_response(409) |> Map.fetch!("code") ==
             "client_lease_lost"

    assert renew(conn, "worker", "other-batch") |> json_response(409)
    assert renew(conn, "worker", nil) |> json_response(400)
    assert renew(conn, ["bad"], batch) |> json_response(400)

    assert conn
           |> put_req_header("authorization", "Bearer other-token")
           |> post("/api/client-lease", %{client_id: "worker", delivery_id: batch})
           |> json_response(409)

    assert post(conn, "/api/client-lease", %{client_id: "worker", delivery_id: batch})
           |> json_response(401)
  end

  test "expired leases cannot be resurrected or steal a replayed batch", %{
    conn: conn,
    batch: batch
  } do
    client = :sys.get_state(Hub).delivery.clients["assistant"]
    Process.cancel_timer(client.timer)
    assert renew(conn, "worker", batch) |> json_response(409)
    send(Hub, {:expire_client, "assistant", "worker", client.lease})
    assert renew(conn, "worker", batch) |> json_response(409)

    {:ok, %{delivery_id: next, requests: [_]}} =
      Hub.poll_delivery("ai-token", client_id: "replacement")

    assert next != batch
    assert renew(conn, "worker", batch) |> json_response(409)
    assert renew(conn, "replacement", next) |> json_response(200)

    assert {:ok, %{requests: []}} =
             Hub.poll_delivery("ai-token", client_id: "replacement", delivery_ack: next)

    assert renew(conn, "replacement", next) |> json_response(409)
  end

  test "a fully cancelled batch can keep its lease until its handlers finish", %{
    conn: conn,
    batch: batch,
    id: id
  } do
    assert {:ok, _} = Hub.cancel("ai-token", id)
    assert :sys.get_state(Hub).delivery.clients["assistant"].http_delivery == nil
    assert renew(conn, "worker", batch) |> json_response(200)

    assert {:ok, %{requests: []}} =
             Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: batch)

    assert renew(conn, "worker", batch) |> json_response(409)
  end

  test "renewal is allowed during drain and completion still requires acknowledgement", %{
    conn: conn,
    batch: batch,
    id: id
  } do
    {:ok, _} = Hub.start_drain()
    on_exit(fn -> Hub.resume_intake() end)
    assert renew(conn, "worker", batch) |> json_response(200)
    assert :ok = Hub.respond("ai-token", id, "text", "done")
    assert renew(conn, "worker", batch) |> json_response(200)
    assert %{drained: false, unacknowledged_batches: 1} = Hub.drain_status()
    {:ok, _} = Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: batch)
    assert %{drained: true} = Hub.drain_status()
  end

  test "websocket sessions cannot use HTTP renewal", %{conn: conn} do
    :ok = Hub.configure(Exiron.HubCase.load_router!(), Telegram.new([]))
    {:ok, _} = Hub.connect_socket("ai-token", client_id: "socket", pid: self())
    assert renew(conn, "socket", "batch") |> json_response(409)
  end

  test "renewal preserves a partial stream and its original request deadline", %{
    conn: conn,
    batch: batch,
    id: id
  } do
    assert {:ok, %{final: false}} = Hub.respond("ai-token", id, "text", "partial", final: false)
    pending = :sys.get_state(Hub).delivery.pending[id]
    assert renew(conn, "worker", batch) |> json_response(200)
    assert :sys.get_state(Hub).delivery.pending[id] == pending
    assert :ok = Hub.respond("ai-token", id, "text", "final")
  end

  defp renew(conn, id, batch),
    do:
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post("/api/client-lease", %{client_id: id, delivery_id: batch})
end
