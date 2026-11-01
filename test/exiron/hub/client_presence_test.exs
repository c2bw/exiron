defmodule Exiron.Hub.ClientPresenceTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.Message

  test "HTTP lease expiry retains contact and separates outstanding work from an active session" do
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    id = incoming(1)
    assert Hub.request_trace(id).client_presence.state == "unassigned"
    {:ok, [_]} = Hub.poll("ai-token", client_id: "worker")
    client = presence()
    assert client.state == "http_polling"
    assert client.client_id == "worker"
    assert client.awaiting_response == 1
    assert %DateTime{} = client.last_contact_at
    assert client.last_contact_kind == "poll"
    assert :sys.get_state(Hub).delivery.pending[id].assigned_client_id == "worker"
    expire()
    assert presence().state == "http_lease_expired"
    assert presence().awaiting_response == 1
    assert presence().last_contact_at == client.last_contact_at
    assert [%{connected: true}] = Hub.status().hooks
    assert Hub.request_trace(id).client_presence.state == "http_lease_expired"
    assert :ok = Hub.respond("ai-token", id, "text", "done")
    assert presence().awaiting_response == 0
    assert [%{connected: false}] = Hub.status().hooks
  end

  test "a replacement client is not credited with a former client's claimed requests" do
    {:ok, []} = Hub.poll("ai-token", client_id: "old")
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token", client_id: "old")
    expire()
    {:ok, []} = Hub.poll("ai-token", client_id: "new")
    assert presence().client_id == "new"
    assert presence().awaiting_response == 0
    assert presence().other_assigned_requests == 1
    info = Hub.request_trace(id).client_presence
    assert info.state == "different_client"
    assert info.client_id == "old"
    assert info.current_client_id == "new"
    assert is_nil(info.last_contact_at)
  end

  test "WebSocket pings and acknowledgements are identified and stale sockets cannot revive presence" do
    socket = start_socket_process()
    {:ok, _} = Hub.connect_socket("ai-token", client_id: "socket", pid: socket)
    assert presence().state == "websocket_connected"
    assert presence().last_contact_kind == "connect"
    id = incoming(1)
    delivery = :sys.get_state(Hub).delivery.clients["assistant"].socket_delivery
    :ok = Hub.complete_socket_delivery("assistant", "socket", socket, delivery.ref)
    _ = :sys.get_state(Hub)
    assert presence().last_contact_kind == "ack"
    :ok = Hub.socket_contact("assistant", "socket", socket)
    _ = :sys.get_state(Hub)
    assert presence().last_contact_kind == "ping"
    contact = presence().last_contact_at
    :ok = Hub.socket_contact("assistant", "socket", self())
    _ = :sys.get_state(Hub)
    assert presence().last_contact_at == contact
    :ok = Hub.disconnect_socket("assistant", "socket", socket)
    assert presence().state == "websocket_disconnected"
    assert Hub.request_trace(id).client_presence.state == "websocket_disconnected"
    assert presence().awaiting_response == 1
    :ok = Hub.socket_contact("assistant", "socket", socket)
    _ = :sys.get_state(Hub)
    assert presence().state == "websocket_disconnected"
    assert presence().last_contact_at == contact
  end

  test "unacknowledged work follows its new recipient after socket redelivery" do
    socket = start_socket_process()
    {:ok, _} = Hub.connect_socket("ai-token", client_id: "old-socket", pid: socket)
    id = incoming(1)
    :ok = Hub.disconnect_socket("assistant", "old-socket", socket)
    assert presence().awaiting_response == 0
    {:ok, [request]} = Hub.poll("ai-token", client_id: "http-worker")
    assert request.req_id == id
    assert presence().awaiting_response == 1
    assert presence().other_assigned_requests == 0
    assert Hub.request_trace(id).client_presence.client_id == "http-worker"
    assert Hub.request_trace(id).client_presence.transport == "http"
  end

  test "idle polls update contact without advancing the published status revision" do
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    revision = Hub.status().revision

    :sys.replace_state(Hub, fn state ->
      update_in(
        state.delivery.client_presence["assistant"].last_contact_at,
        &DateTime.add(&1, -60, :second)
      )
    end)

    old = presence().last_contact_at
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    assert DateTime.compare(presence().last_contact_at, old) == :gt
    assert Hub.status().revision == revision
  end

  test "work counters separate client response waits from active Telegram sends" do
    parent = self()

    :ok =
      Hub.configure(
        load_router!(),
        Exiron.Hub.Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ ->
            send(parent, {:sending, self()})

            receive do
              :release -> {:ok, %{message_id: 901}}
            end
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token", client_id: "worker")

    task =
      start_supervised!(
        {Task, fn -> send(parent, {:response, Hub.respond("ai-token", id, "text", "reply")}) end}
      )

    monitor = Process.monitor(task)
    assert_receive {:sending, sender}
    assert presence().awaiting_response == 0
    assert presence().sending_requests == 1
    send(sender, :release)
    assert_receive {:response, :ok}
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
    assert presence().sending_requests == 0
  end

  test "a current session's transport wins when the same client ID reconnects differently" do
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token", client_id: "worker")
    socket = start_socket_process()
    {:ok, _} = Hub.connect_socket("ai-token", client_id: "worker", pid: socket)
    assert Hub.request_trace(id).client_presence.state == "websocket_connected"
    assert Hub.request_trace(id).client_presence.transport == "websocket"
  end

  test "presence stays scoped to configured hooks and is pruned on route removal" do
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    router = load_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "other", Exiron.Hub.HookToken.hash("other-token"))
    }

    :ok = Hub.configure(router, :sys.get_state(Hub).telegram)
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    {:ok, []} = Hub.poll("other-token", client_id: "private-worker")
    {:ok, scoped} = Hub.status_for_token("ai-token")
    assert [%{name: "assistant", client: %{client_id: "worker"}}] = scoped.hooks
    refute inspect(scoped) =~ "private-worker"
    state = :sys.get_state(Hub)
    reconciled = Exiron.Hub.ClientSessions.reconcile_router(state, router, load_router!())
    refute Map.has_key?(reconciled.delivery.client_presence, "other")
    assert Map.has_key?(reconciled.delivery.client_presence, "assistant")
  end

  defp presence, do: hd(Hub.status().hooks).client

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

  defp expire do
    client = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", client.client_id, client.lease})
    _ = :sys.get_state(Hub)
  end
end
