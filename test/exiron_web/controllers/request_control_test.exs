defmodule ExironWeb.RequestControlTest do
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

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok
  end

  test "state checks are read-only, owned and report cancellation", %{conn: conn} do
    id = incoming(1)
    before = :sys.get_state(Hub)

    result =
      conn |> auth("ai-token") |> get("/api/request-state", req_id: id) |> json_response(200)

    assert result["state"] == "active"
    assert result["expires_in_ms"] > 0
    after_state = :sys.get_state(Hub)

    assert after_state.delivery.clients["assistant"].lease ==
             before.delivery.clients["assistant"].lease

    assert after_state.delivery.queues == before.delivery.queues

    denied =
      conn |> auth("other-token") |> get("/api/request-state", req_id: id) |> json_response(409)

    assert denied["code"] == "request_not_assigned"
    assert {:ok, _} = Hub.cancel("ai-token", id)

    assert conn |> auth("ai-token") |> get("/api/request-state", req_id: id) |> json_response(200) ==
             %{"req_id" => id, "state" => "cancelled", "expires_in_ms" => nil}
  end

  test "expiry remains distinguishable when its trace was already evicted", %{conn: conn} do
    id = incoming(1)

    :sys.replace_state(Hub, fn state ->
      %{state | activity: %{state.activity | traces: %{}, trace_order: []}}
    end)

    send(Hub, {:expire_request, id})
    assert {:ok, %{state: "expired"}} = Hub.request_state("ai-token", id)

    assert conn |> auth("ai-token") |> get("/api/request-state", req_id: id) |> json_response(200) ==
             %{"req_id" => id, "state" => "expired", "expires_in_ms" => nil}

    assert {:error, :request_not_assigned} = Hub.request_state("other-token", id)
  end

  test "completed, missing and invalid states are distinct", %{conn: conn} do
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token", client_id: "worker")
    :ok = Hub.respond("ai-token", id, "text", "done")
    assert {:ok, %{state: "completed"}} = Hub.request_state("ai-token", id)

    assert conn
           |> auth("ai-token")
           |> get("/api/request-state", req_id: "missing")
           |> json_response(404)
           |> Map.fetch!("code") == "request_not_found"

    assert conn
           |> auth("ai-token")
           |> get("/api/request-state")
           |> json_response(400)
           |> Map.fetch!("code") == "invalid_payload"

    assert conn
           |> get("/api/request-state", req_id: id)
           |> json_response(401)
           |> Map.fetch!("code") == "missing_token"
  end

  test "expiry receipts have a fixed retention bound" do
    state = :sys.get_state(Hub)

    state =
      Enum.reduce(1..505, state, fn id, state ->
        Exiron.Hub.RequestControl.expired(state, to_string(id), "assistant")
      end)

    assert map_size(state.delivery.expirations) == 500
    assert length(state.delivery.expiration_order) == 500

    assert {:error, :request_not_found} =
             Exiron.Hub.RequestControl.snapshot(state, "assistant", "1")

    assert {:ok, %{state: "expired"}} =
             Exiron.Hub.RequestControl.snapshot(state, "assistant", "505")
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp incoming(n) do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request #{n}",
          bot_token: "bot-token",
          message_id: n
        )
      )

    hd(Hub.request_traces()).id
  end
end
