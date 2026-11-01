defmodule Exiron.Hub.ClientSessionsIntegrationTest do
  use Exiron.HubCase, async: false

  alias Exiron.Hub
  alias Exiron.Hub.{Message, QueueBuffer, QueueState, Telegram}

  describe "polling clients" do
    test "routed requests are queued when the target client is connected" do
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert %{delivery: %{pending: pending, queues: %{"assistant" => queue}}} =
               :sys.get_state(Hub)

      assert [_request] = QueueBuffer.items(queue)
      assert map_size(pending) == 1
      assert Hub.status().requested == 1
    end

    test "authentication validates credentials without creating a connection lease" do
      assert {:ok, %{hook: "assistant"}} = Hub.authenticate("ai-token")
      assert [%{connected: false, listening: false}] = Hub.status().hooks
    end

    test "routed clients receive Telegram message ids" do
      assert {:ok, []} = Hub.poll("ai-token", listen: true)

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "text", "/ai hello", "bot-token",
            bot_name: "assistant-bot",
            message_id: 1234,
            reply_to_message_id: 1201
          )
        )

      assert {:ok, [request]} = Hub.poll("ai-token", listen: true)
      assert request.msgtype == "request"
      assert request.instance == "assistant-bot"
      assert request.message_id == 1234
      assert request.reply_to_message_id == 1201
    end

    test "clients and status events receive sticker emoji metadata for file messages" do
      sticker_emoji = "\u{1F525}"
      assert {:ok, []} = Hub.poll("ai-token", listen: true)

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "file", "sticker bytes", "bot-token",
            sticker_id: "sticker-id",
            sticker_emoji: sticker_emoji
          )
        )

      assert {:ok, [request]} = Hub.poll("ai-token", listen: true)
      assert request.datatype == "file"
      assert request.sticker_id == "sticker-id"
      assert request.sticker_emoji == sticker_emoji

      assert [
               %{datatype: "file", sticker_id: "sticker-id", sticker_emoji: ^sticker_emoji}
               | _events
             ] =
               Hub.status().events
    end

    test "routed clients receive the source Telegram bot name" do
      assert {:ok, []} = Hub.poll("ai-token")

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "text", "/ai hello", "bot-token", bot_name: "assistant-bot")
        )

      assert {:ok, [request]} = Hub.poll("ai-token")
      assert request.msgtype == "request"
      assert request.instance == "assistant-bot"
    end

    test "routed clients do not receive Telegram bot tokens as fallback instances" do
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert {:ok, [request]} = Hub.poll("ai-token")
      assert request.instance == nil
    end

    test "image events reference lazily stored browser media" do
      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "image bytes">>

      :ok = Hub.incoming_service_message(Message.new(222, 123, "image", png, "bot-token"))

      assert [%{datatype: "image", image_src: image_src}] = Hub.status().events
      assert String.starts_with?(image_src, "/api/event-media/")
      media_id = Path.basename(image_src)

      assert {:ok, %{mime_type: "image/png", bytes: ^png}} =
               Exiron.Hub.EventMediaStore.fetch(media_id, :dashboard)
    end

    test "status events are newest first" do
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "first", "bot-token"))
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "second", "bot-token"))

      assert [%{preview: "second"}, %{preview: "first"} | _events] = Hub.status().events
    end

    test "client events track connects and disconnects without heartbeat noise" do
      assert {:ok, []} = Hub.poll("ai-token", client_id: "listener", listen: true)
      assert {:ok, []} = Hub.poll("ai-token", client_id: "listener")

      assert [
               %{
                 action: "connected",
                 hook: "assistant",
                 client_id: "listener",
                 listening: true
               }
             ] = Hub.status().client_events

      expire_client("assistant", "listener")

      assert [
               %{
                 action: "disconnected",
                 hook: "assistant",
                 client_id: "listener",
                 listening: false
               },
               %{action: "connected", client_id: "listener"}
             ] = Hub.status().client_events
    end

    test "routed requests receive an unavailable response when the target client is disconnected" do
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert_receive {:telegram_sent, "bot-token", %Message{datatype: "text", data: response}}
      assert response == "Hook assistant is not connected."

      assert %{delivery: %{pending: pending, queues: queues}} = :sys.get_state(Hub)
      assert pending == %{}
      refute Map.has_key?(queues, "assistant")
    end

    test "unclaimed queued work does not keep an expired client connected" do
      assert {:ok, []} = Hub.poll("ai-token")
      assert [%{connected: true}] = Hub.status().hooks

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      expire_client("assistant")

      assert [%{connected: false, listening: false, queued: 1}] = Hub.status().hooks
    end

    test "pending request expiry removes the pending entry and queued work" do
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      [{request_id, _pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)
      send(Hub, {:expire_request, request_id})
      state = :sys.get_state(Hub)

      assert state.delivery.pending == %{}
      assert QueueBuffer.items(state.delivery.queues["assistant"]) == []
      assert [%{connected: true, queued: 0}] = Hub.status().hooks
      assert {:ok, []} = Hub.poll("ai-token")
    end

    test "stale client expiry timers do not disconnect a refreshed client" do
      assert {:ok, []} = Hub.poll("ai-token")
      %{lease: stale_lease} = :sys.get_state(Hub).delivery.clients["assistant"]

      assert {:ok, []} = Hub.poll("ai-token")
      send(Hub, {:expire_client, "assistant", "default", stale_lease})
      _ = :sys.get_state(Hub)

      assert [%{connected: true}] = Hub.status().hooks
    end

    test "polling can atomically restore listen mode after client expiry" do
      assert {:ok, []} = Hub.poll("ai-token", listen: true)
      expire_client("assistant")

      assert [%{connected: false, listening: false}] = Hub.status().hooks
      assert {:ok, []} = Hub.poll("ai-token", listen: true)
      assert [%{connected: true, listening: true}] = Hub.status().hooks
    end

    test "each poll replaces the lease listen mode" do
      assert {:ok, []} = Hub.poll("ai-token", listen: true)
      assert [%{listening: true}] = Hub.status().hooks

      assert {:ok, []} = Hub.poll("ai-token")
      assert [%{connected: true, listening: false}] = Hub.status().hooks
    end

    test "a second client id cannot connect while a hook client lease is active" do
      assert {:ok, []} = Hub.poll("ai-token", client_id: "listener", listen: true)

      assert {:error, {:hook_already_connected, retry_after_ms}} =
               Hub.poll("ai-token", client_id: "worker")

      assert retry_after_ms in 1..3000
      assert [%{connected: true, listening: true}] = Hub.status().hooks
    end
  end

  describe "delivery transports" do
    test "websocket connect records lifecycle and drains queued work" do
      assert {:ok, []} = Hub.poll("ai-token", client_id: "socket")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      _ = :sys.get_state(Hub)

      assert {:ok,
              %{
                hook: "assistant",
                client_id: "socket",
                listen: true,
                messages: [request]
              }} = Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

      assert request.msgtype == "request"
      assert [%{connected: true, listening: true, queued: 0}] = Hub.status().hooks
      assert [%{action: "connected", client_id: "socket"}] = Hub.status().client_events
    end

    test "websocket client receives newly queued routed work" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert_receive {:exiron_messages, _delivery_ref, [request]}
      assert request.msgtype == "request"
      assert request.data == Base.encode64("/ai hello")
      assert [%{queued: 0}] = Hub.status().hooks
    end

    test "websocket listen client receives listen messages" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "ambient", "bot-token"))

      assert_receive {:exiron_messages, _delivery_ref, [listen]}
      assert listen.msgtype == "listen"
      assert listen.data == Base.encode64("ambient")
    end

    test "websocket listen client receives routed messages only once as requests" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert_receive {:exiron_messages, _delivery_ref, [request]}
      assert request.msgtype == "request"
      assert request.data == Base.encode64("/ai hello")
      refute_receive {:exiron_messages, _delivery_ref, _messages}
    end

    test "websocket listen all client receives routed messages as listen and request" do
      assert {:ok, %{listen: :all, messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: :all, pid: self())

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert_receive {:exiron_messages, _delivery_ref, [request, listen]}
      assert listen.msgtype == "listen"
      assert request.msgtype == "request"
      assert listen.data == Base.encode64("/ai hello")
      assert request.data == Base.encode64("/ai hello")
      refute_receive {:exiron_messages, _delivery_ref, _messages}
    end

    test "websocket in-flight requests count toward the hook queue cap" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

      :sys.replace_state(
        Hub,
        &%{&1 | settings: %{&1.settings | max_queue_per_hook: 1}}
      )

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai first", "bot-token"))
      assert_receive {:exiron_messages, delivery_ref, [request]}
      assert Base.decode64!(request.data) == "/ai first"

      state = :sys.get_state(Hub)
      assert QueueBuffer.items(state.delivery.queues["assistant"]) == []
      assert state.delivery.clients["assistant"].socket_delivery.count == 1

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai second", "bot-token"))

      assert_receive {:telegram_sent, "bot-token",
                      %Message{data: "Hook assistant is overloaded. Please try again later."}}

      refute_receive {:exiron_messages, _delivery_ref, _messages}
      assert map_size(:sys.get_state(Hub).delivery.pending) == 1
      assert [%{reason: :max_queue_per_hook} | _events] = Hub.status().overload_events

      Hub.complete_socket_delivery("assistant", "socket", self(), delivery_ref)
      assert %{socket_delivery: nil} = :sys.get_state(Hub).delivery.clients["assistant"]
    end

    test "websocket in-flight requests count toward the hook byte cap" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

      first = Message.new(222, 123, "text", "/ai first", "bot-token")
      byte_cap = Message.queued_payload_size(first)

      :sys.replace_state(
        Hub,
        &%{&1 | settings: %{&1.settings | max_queue_bytes_per_hook: byte_cap}}
      )

      :ok = Hub.incoming_service_message(first)
      assert_receive {:exiron_messages, _delivery_ref, [_request]}

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai second", "bot-token"))

      assert_receive {:telegram_sent, "bot-token",
                      %Message{data: "Hook assistant is overloaded. Please try again later."}}

      assert [%{reason: :max_queue_bytes_per_hook} | _events] = Hub.status().overload_events
      refute_receive {:exiron_messages, _delivery_ref, _messages}
    end

    test "websocket acknowledges one batch before receiving the queued batch" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

      :sys.replace_state(
        Hub,
        &%{&1 | settings: %{&1.settings | max_queue_per_hook: 2}}
      )

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai first", "bot-token"))
      assert_receive {:exiron_messages, first_ref, [first]}

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai second", "bot-token"))
      _ = :sys.get_state(Hub)

      refute_receive {:exiron_messages, _delivery_ref, _messages}

      assert [%{data: second_data}] =
               QueueBuffer.items(:sys.get_state(Hub).delivery.queues["assistant"])

      assert Base.decode64!(second_data) == "/ai second"

      Hub.complete_socket_delivery("assistant", "socket", self(), first_ref)

      assert_receive {:exiron_messages, second_ref, [second]}
      assert second_ref != first_ref
      assert Base.decode64!(first.data) == "/ai first"
      assert Base.decode64!(second.data) == "/ai second"
    end

    test "websocket in-flight listen messages count toward lossy queue limits" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

      :sys.replace_state(
        Hub,
        &%{&1 | settings: %{&1.settings | max_queue_per_hook: 1}}
      )

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "first", "bot-token"))
      assert_receive {:exiron_messages, _delivery_ref, [listen]}
      assert Base.decode64!(listen.data) == "first"

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "second", "bot-token"))
      _ = :sys.get_state(Hub)

      refute_receive {:exiron_messages, _delivery_ref, _messages}
      assert QueueBuffer.items(:sys.get_state(Hub).delivery.queues["assistant"]) == []
      assert Enum.any?(Hub.status().events, &(&1.kind == "listen_dropped"))
    end

    test "a second websocket client id cannot connect while a hook client is active" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

      assert {:error, {:hook_already_connected, retry_after_ms}} =
               Hub.connect_socket("ai-token", client_id: "other", listen: true, pid: self())

      assert retry_after_ms == 3000
      assert [%{connected: true, listening: true}] = Hub.status().hooks
    end

    test "same websocket client id replaces the previous socket" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

      replacement = start_socket_process()

      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: replacement)

      assert_receive {:exiron_socket_replaced, ^replacement}
      assert [%{connected: true, listening: true}] = Hub.status().hooks

      assert %{pid: ^replacement, monitor: monitor} =
               :sys.get_state(Hub).delivery.clients["assistant"]

      assert is_reference(monitor)

      send(replacement, :stop)
    end

    test "dead websocket process releases its lease and requeues its delivery" do
      socket = start_socket_process()

      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token",
                 client_id: "dead-socket",
                 listen: false,
                 pid: socket
               )

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      state = :sys.get_state(Hub)

      assert %{
               socket_delivery: %{ref: first_ref, items: [%{req_id: request_id}]},
               monitor: monitor
             } = state.delivery.clients["assistant"]

      assert is_reference(monitor)
      assert state.delivery.pending[request_id].claimed?

      socket_ref = Process.monitor(socket)
      Process.exit(socket, :kill)
      assert_receive {:DOWN, ^socket_ref, :process, ^socket, :killed}

      assert_eventually(fn ->
        state = :sys.get_state(Hub)
        refute Map.has_key?(state.delivery.clients, "assistant")
        assert [%{req_id: ^request_id}] = QueueBuffer.items(state.delivery.queues["assistant"])
        refute state.delivery.pending[request_id].claimed?
      end)

      assert {:ok, %{delivery_ref: second_ref, messages: [%{req_id: ^request_id}]}} =
               Hub.connect_socket(
                 "ai-token",
                 client_id: "replacement-socket",
                 listen: false,
                 pid: self()
               )

      assert second_ref != first_ref
    end

    test "a replaced websocket process cannot disconnect its replacement" do
      first = start_socket_process()
      replacement = start_socket_process()

      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: first)

      first_monitor = :sys.get_state(Hub).delivery.clients["assistant"].monitor

      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token",
                 client_id: "socket",
                 listen: true,
                 pid: replacement
               )

      assert %{pid: ^replacement, monitor: replacement_monitor} =
               :sys.get_state(Hub).delivery.clients["assistant"]

      refute replacement_monitor == first_monitor

      first_ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^first_ref, :process, ^first, :killed}

      assert_eventually(fn ->
        assert %{pid: ^replacement, monitor: ^replacement_monitor} =
                 :sys.get_state(Hub).delivery.clients["assistant"]

        assert [%{connected: true, listening: true}] = Hub.status().hooks
      end)

      assert :ok = Hub.disconnect_socket("assistant", "socket", replacement)
      send(replacement, :stop)
    end

    test "HTTP polling does not replace an active websocket with the same client id" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

      assert {:error, {:hook_already_connected, 3000}} =
               Hub.poll("ai-token", client_id: "socket", listen: false)

      refute_receive {:exiron_socket_replaced, _pid}
      assert [%{connected: true, listening: true}] = Hub.status().hooks
    end

    test "websocket disconnect removes the client immediately" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

      assert :ok = Hub.disconnect_socket("assistant", "socket", self())

      assert [%{connected: false, listening: false}] = Hub.status().hooks
      assert [%{action: "disconnected"}, %{action: "connected"}] = Hub.status().client_events
    end

    test "websocket disconnect requeues an unacknowledged routed delivery" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      assert_receive {:exiron_messages, first_ref, [first]}

      assert :ok = Hub.disconnect_socket("assistant", "socket", self())

      state = :sys.get_state(Hub)
      assert [%{req_id: request_id}] = QueueBuffer.items(state.delivery.queues["assistant"])
      assert request_id == first.req_id
      refute state.delivery.pending[request_id].claimed?
      refute QueueState.hook_available?(state, "assistant")

      assert {:ok, %{delivery_ref: second_ref, messages: [second]}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

      assert second_ref != first_ref
      assert second.req_id == first.req_id
      assert :sys.get_state(Hub).delivery.pending[request_id].claimed?
    end

    test "websocket disconnect does not requeue lossy listen deliveries" do
      assert {:ok, %{messages: []}} =
               Hub.connect_socket("ai-token", client_id: "socket", listen: true, pid: self())

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "ambient", "bot-token"))
      assert_receive {:exiron_messages, _delivery_ref, [%{msgtype: "listen"}]}

      assert :ok = Hub.disconnect_socket("assistant", "socket", self())
      assert QueueBuffer.items(:sys.get_state(Hub).delivery.queues["assistant"]) == []
    end

    test "explicit HTTP polling redelivers a batch until it is acknowledged" do
      assert {:ok, %{delivery_id: nil, requests: []}} =
               Hub.poll_delivery("ai-token", client_id: "poller")

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert {:ok, %{delivery_id: delivery_id, requests: [first]}} =
               Hub.poll_delivery("ai-token", client_id: "poller")

      assert is_binary(delivery_id)

      assert {:ok, %{delivery_id: ^delivery_id, requests: [repeated]}} =
               Hub.poll_delivery("ai-token", client_id: "poller")

      assert repeated.req_id == first.req_id

      assert {:ok, %{delivery_id: nil, requests: []}} =
               Hub.poll_delivery("ai-token", client_id: "poller", delivery_ack: delivery_id)
    end

    test "explicit HTTP delivery is requeued when its client lease expires" do
      assert {:ok, %{requests: []}} = Hub.poll_delivery("ai-token", client_id: "poller")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert {:ok, %{delivery_id: first_id, requests: [first]}} =
               Hub.poll_delivery("ai-token", client_id: "poller")

      expire_client("assistant", "poller")
      refute :sys.get_state(Hub).delivery.pending[first.req_id].claimed?

      assert {:ok, %{delivery_id: second_id, requests: [repeated]}} =
               Hub.poll_delivery("ai-token", client_id: "poller")

      assert second_id != first_id
      assert repeated.req_id == first.req_id
    end
  end

  describe "lease and status timing" do
    test "a different client id can connect after the hook client lease expires" do
      assert {:ok, []} = Hub.poll("ai-token", client_id: "listener", listen: true)
      expire_client("assistant", "listener")
      assert [%{connected: false, listening: false}] = Hub.status().hooks

      assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
      assert [%{connected: true, listening: false}] = Hub.status().hooks
    end

    test "outstanding work keeps a hook available after its polling lease expires" do
      assert {:ok, []} = Hub.poll("ai-token", client_id: "slow-worker")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai first", "bot-token"))
      assert {:ok, [request]} = Hub.poll("ai-token", client_id: "slow-worker")

      expire_client("assistant", "slow-worker")
      assert [%{connected: true}] = Hub.status().hooks

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai second", "bot-token"))

      assert %{delivery: %{queues: %{"assistant" => queue}, pending: pending}} =
               :sys.get_state(Hub)

      assert [_queued] = QueueBuffer.items(queue)
      assert map_size(pending) == 2

      assert :ok = Hub.respond("ai-token", request.req_id, "text", "done")
      assert %{requested: 1, hooks: [%{connected: false, queued: 1}]} = Hub.status()
    end

    test "client expiry timeout is configurable" do
      hub_config = Application.get_env(:exiron, :hub, [])
      Application.put_env(:exiron, :hub, Keyword.put(hub_config, :client_timeout, 12_345))

      on_exit(fn ->
        Application.put_env(:exiron, :hub, hub_config)
      end)

      :ok = Hub.configure(load_router!(), Telegram.new([%{chat_id: 123, bot_token: "bot-token"}]))
      assert {:ok, []} = Hub.poll("ai-token")

      remaining = Process.read_timer(:sys.get_state(Hub).delivery.clients["assistant"].timer)
      assert remaining <= 12_345
      assert remaining > 10_000
    end

    test "client expiry timeout defaults to a quick heartbeat" do
      :ok = Hub.configure(load_router!(), Telegram.new([%{chat_id: 123, bot_token: "bot-token"}]))
      assert {:ok, []} = Hub.poll("ai-token")

      remaining = Process.read_timer(:sys.get_state(Hub).delivery.clients["assistant"].timer)
      assert remaining <= 3000
      assert remaining > 2500
    end

    test "empty HTTP lease renewals do not rebroadcast unchanged status" do
      :ok = Hub.subscribe_status()

      assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
      assert_receive {:hub_status_delta, %{collections: %{hooks: _hooks}}}

      assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
      refute_receive {:hub_status_delta, _delta}, 50

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      assert_receive {:hub_status_delta, %{collections: %{events: _events}}}

      assert {:ok, [_request]} = Hub.poll("ai-token", client_id: "worker")
      assert_receive {:hub_status_delta, %{collections: %{hooks: _hooks}}}
    end

    test "pending request expiry timeout is configurable" do
      hub_config = Application.get_env(:exiron, :hub, [])
      Application.put_env(:exiron, :hub, Keyword.put(hub_config, :pending_timeout, 12_345))

      on_exit(fn ->
        Application.put_env(:exiron, :hub, hub_config)
      end)

      :ok = Hub.configure(load_router!(), Telegram.new([%{chat_id: 123, bot_token: "bot-token"}]))
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      [{_request_id, pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)
      remaining = Process.read_timer(pending.timer)
      assert remaining <= 12_345
      assert remaining > 10_000
    end
  end
end
