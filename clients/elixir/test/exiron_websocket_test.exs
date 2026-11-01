defmodule ExironWebsocketTest do
  use ExUnit.Case, async: true

  alias ExironClient.{Error, Message, Protocol, SocketPoller}
  alias ExironClient.FixtureHelpers

  test "websocket poller waits for the server connected frame before on_connect" do
    parent = self()

    state =
      parent
      |> FixtureHelpers.socket_state(handler: fn _message -> :ok end)
      |> Map.put(:connected?, false)

    assert {:ok, state} = SocketPoller.handle_connect(nil, state)
    refute state.connected?
    refute_receive :connected

    connected = Jason.encode!(FixtureHelpers.contract_json("websocket_connected_frame.json"))

    assert {:ok, state} = SocketPoller.handle_frame({:text, connected}, state)
    assert state.connected?
    assert_receive :connected
    assert_receive {:protocol, %Protocol{} = protocol}
    assert protocol.version == ExironClient.Protocol.Generated.version()
    assert Protocol.supports?(protocol, "websocket")

    assert {:ok, state} = SocketPoller.handle_frame({:text, connected}, state)
    refute_receive :connected
    refute_receive {:protocol, _protocol}

    assert :ok = SocketPoller.terminate(:normal, state)
  end

  test "websocket poller reconnects after recoverable server error frames" do
    parent = self()
    state = FixtureHelpers.socket_state(parent, handler: fn _message -> :ok end)

    frame = Jason.encode!(FixtureHelpers.contract_json("websocket_error_frame.json"))

    assert {:ok, state} = SocketPoller.handle_frame({:text, frame}, state)

    assert %Error{
             reason: :hook_already_connected,
             code: "hook_already_connected",
             retry_after_ms: 12
           } = state.last_error

    assert {:reconnect, state} =
             SocketPoller.handle_disconnect(
               %{reason: {:remote, 4009, "hook already connected"}},
               state
             )

    assert state.connected? == false
    assert state.last_error == nil
    assert_receive {:disconnected, %Error{reason: :hook_already_connected}}
  end

  test "websocket poller normalizes malformed server error frames" do
    parent = self()
    state = FixtureHelpers.socket_state(parent, handler: fn _message -> :ok end)
    frame = Jason.encode!(%{type: "error", error: nil})

    assert catch_exit(SocketPoller.handle_frame({:text, frame}, state)) ==
             %Error{
               reason: :server_error,
               message: nil,
               status: 409,
               body: %{"error" => nil, "type" => "error"}
             }
  end

  test "websocket poller paces reconnects with server retry hints" do
    parent = self()

    client =
      FixtureHelpers.socket_client(
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 50,
          max_delay_ms: 100,
          max_retry_time_ms: 1_000,
          sleep: fn _delay_ms -> :ok end
        ]
      )

    state = FixtureHelpers.socket_state(parent, handler: fn _message -> :ok end, client: client)

    assert SocketPoller.reconnect_delay_ms(
             state,
             Error.new(:hook_already_connected, "hook already connected", retry_after_ms: 12)
           ) == 12

    assert SocketPoller.reconnect_delay_ms(
             state,
             Error.new(:transport_error, "connection closed")
           ) == 50
  end

  test "shutdown reports a connected session once even when termination sees stale state" do
    state = FixtureHelpers.socket_state(self(), handler: fn _message -> :ok end)
    assert :ok = SocketPoller.terminate(:shutdown, state)
    assert_receive {:disconnected, :shutdown}
    assert :ok = SocketPoller.terminate(:shutdown, state)
    refute_receive {:disconnected, _reason}
  end

  test "an unaccepted session never emits a disconnect callback" do
    state = FixtureHelpers.socket_state(self(), handler: fn _message -> :ok end)
    assert :ok = SocketPoller.terminate(:shutdown, %{state | connected?: false})
    refute_receive {:disconnected, _reason}
  end

  test "retry budget and delay reset only after the server accepts the session" do
    client =
      FixtureHelpers.socket_client(
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 10,
          max_delay_ms: 100,
          max_retry_time_ms: 1_000,
          sleep: fn _ -> :ok end
        ]
      )

    state = FixtureHelpers.socket_state(self(), handler: fn _ -> :ok end, client: client)
    assert {:ok, state} = SocketPoller.handle_connect(nil, state)
    assert {:reconnect, state} = SocketPoller.handle_disconnect(%{reason: :closed}, state)
    started_at = state.reconnect_started_at_ms
    assert is_integer(started_at)
    assert state.client.reconnect_backoff[:current_delay_ms] == 20
    assert {:ok, state} = SocketPoller.handle_connect(nil, state)
    assert state.reconnect_started_at_ms == started_at
    assert state.client.reconnect_backoff[:current_delay_ms] == 20
    connected = Jason.encode!(FixtureHelpers.contract_json("websocket_connected_frame.json"))
    assert {:ok, state} = SocketPoller.handle_frame({:text, connected}, state)
    assert state.reconnect_started_at_ms == nil
    assert state.client.reconnect_backoff[:current_delay_ms] == 10
    assert_receive :connected
    assert :ok = SocketPoller.terminate(:shutdown, state)
  end

  test "websocket poller uses configured exponential reconnect backoff" do
    parent = self()
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      FixtureHelpers.socket_client(
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 10,
          max_delay_ms: 25,
          max_retry_time_ms: 1_000,
          sleep: fn delay_ms -> Agent.update(sleeps, &[delay_ms | &1]) end
        ]
      )

    state = FixtureHelpers.socket_state(parent, handler: fn _message -> :ok end, client: client)

    assert {:reconnect, state} = SocketPoller.handle_disconnect(%{reason: :closed}, state)
    assert {:reconnect, state} = SocketPoller.handle_disconnect(%{reason: :closed}, state)

    assert Agent.get(sleeps, &Enum.reverse/1) == [10, 20]
    assert Keyword.fetch!(state.client.reconnect_backoff, :current_delay_ms) == 25
    assert_receive {:disconnected, %Error{reason: :transport_error}}
  end

  test "websocket poller stops reconnecting after the configured retry time" do
    parent = self()
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      FixtureHelpers.socket_client(
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 20,
          max_delay_ms: 30_000,
          max_retry_time_ms: 19,
          sleep: fn delay_ms -> Agent.update(sleeps, &[delay_ms | &1]) end
        ]
      )

    state = FixtureHelpers.socket_state(parent, handler: fn _message -> :ok end, client: client)

    assert catch_exit(SocketPoller.handle_disconnect(%{reason: :closed}, state)) ==
             %Error{reason: :transport_error, message: ":closed", body: :closed}

    assert Agent.get(sleeps, &Enum.reverse/1) == []
    assert_receive {:disconnected, %Error{reason: :transport_error}}
  end

  test "websocket poller decodes shared frame fixtures" do
    parent = self()

    state =
      FixtureHelpers.socket_state(parent,
        handler: fn message -> send(parent, {:handled, message}) end
      )

    connected = Jason.encode!(FixtureHelpers.contract_json("websocket_connected_frame.json"))
    messages = Jason.encode!(FixtureHelpers.contract_json("websocket_messages_frame.json"))
    pong = Jason.encode!(FixtureHelpers.contract_json("websocket_pong_frame.json"))

    assert {:ok, state} = SocketPoller.handle_frame({:text, connected}, state)
    assert {:ok, state} = SocketPoller.handle_frame({:text, messages}, state)
    assert {:ok, _state} = SocketPoller.handle_frame({:text, pong}, state)

    assert_receive {:handled, %Message{req_id: "req-1", data: "hello"}}
  end

  test "websocket poller preserves base URL path prefixes" do
    client =
      ExironClient.new(
        base_url: "http://example.test/exiron/",
        token: "ai-token",
        client_id: "poller",
        listen: true
      )

    uri = URI.parse(SocketPoller.socket_url(client))

    assert %{scheme: "ws", host: "example.test", path: "/exiron/api/socket"} = uri
    assert URI.decode_query(uri.query) == %{"client_id" => "poller", "listen" => "true"}
  end

  test "websocket poller supports listen all mode" do
    client =
      ExironClient.new(
        base_url: "http://example.test/",
        token: "ai-token",
        client_id: "poller",
        listen: :all
      )

    uri = URI.parse(SocketPoller.socket_url(client))

    assert URI.decode_query(uri.query) == %{"client_id" => "poller", "listen" => "all"}
  end

  test "websocket poller stops after replacement close" do
    parent = self()
    state = FixtureHelpers.socket_state(parent, handler: fn _message -> :ok end)

    assert catch_exit(
             SocketPoller.handle_disconnect(%{reason: {:remote, 1000, "replaced"}}, state)
           ) ==
             %Error{
               reason: :client_replaced,
               message: "websocket client replaced",
               body: {:remote, 1000, "replaced"}
             }

    assert_receive {:disconnected, %Error{reason: :client_replaced}}
  end

  test "websocket poller stops after fatal handshake response" do
    parent = self()

    state =
      FixtureHelpers.socket_state(parent, handler: fn _message -> :ok end)
      |> Map.put(:connected?, false)

    assert %Error{reason: :invalid_token, status: 401} =
             catch_exit(
               SocketPoller.handle_disconnect(
                 %{reason: %WebSockex.RequestError{code: 401, message: "Unauthorized"}},
                 state
               )
             )

    refute_receive {:disconnected, _reason}
  end

  test "websocket poller start_link returns normalized fatal handshake errors" do
    port = FixtureHelpers.fatal_handshake_server!(401, "Unauthorized")

    client =
      ExironClient.new(
        base_url: "http://127.0.0.1:#{port}",
        token: "wrong-token",
        client_id: "poller"
      )

    assert {:error, %Error{reason: :invalid_token, status: 401}} =
             ExironClient.Poller.start_link(
               runtime_reporting: false,
               client: client,
               handler: fn _message -> :ok end
             )
  end

  test "websocket poller reports handler failures before stopping" do
    parent = self()

    state =
      FixtureHelpers.socket_state(parent, handler: fn _message -> {:error, :handler_failed} end)

    frame =
      Jason.encode!(%{
        type: "messages",
        delivery_id: "delivery-failed",
        messages: [
          %{msgtype: "request", req_id: "req-1", datatype: "text", data: Base.encode64("hello")}
        ]
      })

    assert {:ok, state} = SocketPoller.handle_frame({:text, frame}, state)
    assert_receive {:handler_failed, worker_pid, job_ref, :handler_failed}
    assert worker_pid == state.worker_pid
    assert job_ref == state.worker_job_ref

    assert catch_exit(
             SocketPoller.handle_info(
               {:handler_failed, worker_pid, job_ref, :handler_failed},
               state
             )
           ) == :handler_failed

    assert_receive {:disconnected, :handler_failed}
    assert :ok = SocketPoller.terminate(:handler_failed, state)
    refute_receive {:disconnected, _reason}
  end

  test "websocket poller backpressures frames while the handler worker is busy" do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    acceptor =
      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           send(parent, :socket_accepted)

           receive do
             :close_socket -> :gen_tcp.close(socket)
           end
         end},
        id: make_ref(),
        restart: :temporary
      )

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true, packet: :raw])

    assert_receive :socket_accepted

    conn = %WebSockex.Conn{conn_mod: :gen_tcp, transport: :tcp, socket: socket}

    state =
      FixtureHelpers.socket_state(
        parent,
        handler: fn message ->
          send(parent, {:handler_started, message.req_id, self()})

          if message.req_id == "req-1" do
            receive do
              :release_handler -> :ok
            end
          end
        end
      )
      |> Map.put(:conn, conn)

    first_frame = FixtureHelpers.websocket_messages_frame("req-1", "first")
    second_frame = FixtureHelpers.websocket_messages_frame("req-2", "second")

    assert {:ok, state} = SocketPoller.handle_frame({:text, first_frame}, state)
    assert_receive {:handler_started, "req-1", worker_pid}
    assert {:ok, [active: false]} = :inet.getopts(socket, [:active])

    task =
      start_supervised!(
        {Task,
         fn ->
           send(parent, :second_frame_started)

           send(
             parent,
             {:second_frame_result, SocketPoller.handle_frame({:text, second_frame}, state)}
           )
         end},
        id: make_ref(),
        restart: :temporary
      )

    task_ref = Process.monitor(task)
    assert_receive :second_frame_started
    refute_receive {:second_frame_result, _result}, 20
    assert {:message_queue_len, 1} = Process.info(worker_pid, :message_queue_len)

    send(worker_pid, :release_handler)

    assert_receive {:second_frame_result, {:ok, next_state}}
    assert_receive {:handler_started, "req-2", ^worker_pid}
    assert_receive {:DOWN, ^task_ref, :process, ^task, :normal}

    assert_receive {:handler_complete, ^worker_pid, first_job_ref}
    assert first_job_ref == state.worker_job_ref
    assert_receive {:handler_complete, ^worker_pid, job_ref}
    assert job_ref == next_state.worker_job_ref

    assert {:reply, {:text, acknowledgement}, resumed_state} =
             SocketPoller.handle_info({:handler_complete, worker_pid, job_ref}, next_state)

    assert Jason.decode!(acknowledgement) == %{
             "type" => "ack",
             "delivery_id" => next_state.worker_delivery_id
           }

    assert {:ok, [active: :once]} = :inet.getopts(socket, [:active])

    assert :ok = SocketPoller.terminate(:normal, resumed_state)
    send(acceptor, :close_socket)
    :gen_tcp.close(socket)
    :gen_tcp.close(listener)
  end

  test "websocket poller terminates a running handler worker" do
    parent = self()

    state =
      FixtureHelpers.socket_state(
        parent,
        handler: fn _message ->
          send(parent, {:handler_started, self()})

          receive do
            :release_handler -> :ok
          end
        end
      )

    frame = FixtureHelpers.websocket_messages_frame("req-1", "hello")

    assert {:ok, state} = SocketPoller.handle_frame({:text, frame}, state)
    assert_receive {:handler_started, worker_pid}
    worker_ref = Process.monitor(worker_pid)

    assert :ok = SocketPoller.terminate(:normal, state)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :shutdown}
  end

  test "websocket poller does not heartbeat-timeout while handling a message" do
    parent = self()

    state =
      FixtureHelpers.socket_state(
        parent,
        handler: fn _message ->
          send(parent, {:handler_started, self()})

          receive do
            :release_handler -> :ok
          end
        end
      )

    frame =
      Jason.encode!(%{
        type: "messages",
        messages: [
          %{msgtype: "request", req_id: "req-1", datatype: "text", data: Base.encode64("hello")}
        ]
      })

    assert {:ok, state} = SocketPoller.handle_frame({:text, frame}, state)
    assert_receive {:handler_started, worker_pid}
    state = %{state | last_seen_ms: System.monotonic_time(:millisecond) - 20}
    assert {:reply, {:text, payload}, _state} = SocketPoller.handle_info({:ping, nil}, state)
    assert %{"type" => "ping"} = Jason.decode!(payload)
    send(worker_pid, :release_handler)
    refute_receive {:disconnected, _reason}
  end

  test "websocket poller ignores stale heartbeat messages" do
    parent = self()

    state =
      parent
      |> FixtureHelpers.socket_state(handler: fn _message -> :ok end)
      |> Map.put(:ping_ref, make_ref())

    assert {:ok, ^state} = SocketPoller.handle_info({:ping, make_ref()}, state)
    refute_receive {:disconnected, _reason}
  end

  test "websocket poller closes and reports disconnect after heartbeat timeout" do
    parent = self()

    state =
      parent
      |> FixtureHelpers.socket_state(handler: fn _message -> :ok end)
      |> Map.put(:last_seen_ms, System.monotonic_time(:millisecond) - 20)

    assert {:close, {4000, "heartbeat timeout"}, state} =
             SocketPoller.handle_info({:ping, nil}, state)

    assert state.connected? == false
    assert %Error{reason: :transport_error} = state.last_error
    assert_receive {:disconnected, %Error{reason: :transport_error}}
    refute_receive :"$websockex_close_timeout"
  end
end
