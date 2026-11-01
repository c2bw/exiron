defmodule ExironWeb.ClientRetirementTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.Message

  setup do
    :ok = Hub.configure(Exiron.HubCase.load_router!(), Exiron.Hub.Telegram.new([]))
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok
  end

  test "retirement confirms only the completed batch, leaves queued work intact, and releases ownership",
       %{conn: conn} do
    :ok = incoming("first")
    {:ok, batch} = Hub.poll_delivery("ai-token", client_id: "worker")
    :ok = incoming("second")
    before = :sys.get_state(Hub)
    body = %{client_id: "worker", delivery_id: batch.delivery_id}
    assert conn |> post("/api/client-retire", body) |> json_response(401)

    assert conn
           |> auth()
           |> post("/api/client-retire", %{body | client_id: "wrong"})
           |> json_response(409)

    assert conn
           |> auth()
           |> post("/api/client-retire", %{body | delivery_id: "wrong"})
           |> json_response(409)

    assert :sys.get_state(Hub).delivery == before.delivery

    assert conn |> auth() |> post("/api/client-retire", body) |> json_response(200) == %{
             "ok" => true
           }

    assert :sys.get_state(Hub).delivery.clients == %{}
    assert map_size(:sys.get_state(Hub).delivery.pending) == 2
    {:ok, %{requests: [next]}} = Hub.poll_delivery("ai-token", client_id: "replacement")
    assert Base.decode64!(next.data) == "/ai second"
    refute next.req_id == hd(batch.requests).req_id
  end

  test "a normal acknowledgement race preserves and requeues the newer HTTP batch" do
    :ok = incoming("first")
    {:ok, first} = Hub.poll_delivery("ai-token", client_id: "worker")
    :ok = incoming("second")

    {:ok, second} =
      Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: first.delivery_id)

    assert {:ok, %{ok: true}} = Hub.retire_client("ai-token", "worker", first.delivery_id)
    {:ok, replayed} = Hub.poll_delivery("ai-token", client_id: "replacement")
    assert Enum.map(replayed.requests, & &1.req_id) == Enum.map(second.requests, & &1.req_id)
  end

  test "expired and replaced sessions reject stale retirement even with the same client ID" do
    :ok = incoming("first")
    {:ok, first} = Hub.poll_delivery("ai-token", client_id: "worker")
    client = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", "worker", client.lease})
    _ = :sys.get_state(Hub)

    assert {:error, :client_lease_lost} =
             Hub.retire_client("ai-token", "worker", first.delivery_id)

    {:ok, replacement} = Hub.poll_delivery("ai-token", client_id: "worker")
    assert replacement.delivery_id != first.delivery_id

    assert {:error, :client_lease_lost} =
             Hub.retire_client("ai-token", "worker", first.delivery_id)

    assert :sys.get_state(Hub).delivery.clients["assistant"].http_delivery.ref ==
             replacement.delivery_id
  end

  test "WebSocket acknowledgement race is fenced and requeues unfinished newer work" do
    # Existing idle HTTP ownership is replaced using the same ID.
    {:ok, _} = Hub.connect_socket("ai-token", client_id: "worker", pid: self())
    :ok = incoming("first")
    assert_receive {:exiron_messages, first, [_]}
    :ok = incoming("second")
    Hub.complete_socket_delivery("assistant", "worker", self(), first)
    assert_receive {:exiron_messages, _second, [message]}
    assert {:ok, %{ok: true}} = Hub.retire_client("ai-token", "worker", first)
    {:ok, %{requests: [replayed]}} = Hub.poll_delivery("ai-token", client_id: "replacement")
    assert replayed.req_id == message.req_id
  end

  test "a cancelled empty HTTP batch can retire using its fenced batch reference" do
    :ok = incoming("first")
    {:ok, batch} = Hub.poll_delivery("ai-token", client_id: "worker")
    assert {:ok, _} = Hub.cancel("ai-token", hd(batch.requests).req_id)
    assert {:ok, %{ok: true}} = Hub.retire_client("ai-token", "worker", batch.delivery_id)
    assert :sys.get_state(Hub).delivery.clients == %{}
  end

  defp incoming(text),
    do: Hub.incoming_service_message(Message.new(222, 123, "text", "/ai " <> text))

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer ai-token")
end
