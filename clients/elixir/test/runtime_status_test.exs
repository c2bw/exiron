defmodule ExironClient.RuntimeStatusTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Poller, SocketPoller, SocketWorker, FixtureHelpers}

  for graceful <- [false, true] do
    @graceful graceful
    test "status stays responsive during concurrent HTTP handlers (graceful=#{graceful})" do
      parent = self()
      client = client()

      pid =
        start_supervised!(
          {Poller,
           client: client,
           transport: :http,
           graceful_shutdown: @graceful,
           interval_ms: 1000,
           handler_concurrency: 2,
           on_disconnect: fn _ -> send(parent, {:disconnect_status, Poller.status(self())}) end,
           handler: fn _ ->
             send(parent, {:entered, self()})
             receive do: (:release -> :ok)
           end}
        )

      assert_receive {:entered, first}, 1000
      assert_receive {:entered, second}, 1000
      assert {:ok, status} = Poller.status(pid)
      assert status.phase == :handling
      assert status.active_handlers == 2
      assert status.batch_size == 2
      assert status.batch_completed == 0
      assert status.connected?
      assert is_integer(status.last_connected_at)
      assert status.batch_age_ms >= 0
      refute inspect(status) =~ "private-"
      refute inspect(status) =~ "req-1"

      monitor = Process.monitor(pid)

      if @graceful do
        ref = make_ref()
        send(pid, {:client_drain, self(), ref, ExironClient.ClientDrain.now() + 2000})
        _ = :sys.get_state(pid)
        assert {:ok, draining} = Poller.status(pid)
        assert draining.phase == :draining
        assert draining.active_handlers == 2
        assert draining.drain_remaining_ms > 0
        assert draining.drain_deadline >= draining.drain_started_at
        send(first, :release)
        send(second, :release)
        assert_receive {:client_drain_result, ^ref, :ok}, 1000
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
      else
        first_ref = Process.monitor(first)
        second_ref = Process.monitor(second)
        send(first, :release)
        send(second, :release)
        assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}, 1000
        assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}, 1000
        _ = :sys.get_state(pid)
        assert {:ok, completed} = Poller.status(pid)
        assert completed.phase == :waiting
        assert completed.active_handlers == 0
        assert completed.batch_completed == 2
        assert completed.batch_age_ms == 0
        stop_supervised!(Poller)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 1000
      end

      # Normal draining invokes terminate/2. Supervisor exit signals in default
      # mode retain their existing behavior and need not invoke that callback.
      if @graceful do
        assert_receive {:disconnect_status, {:ok, %{connected?: false}}}
      end

      assert {:error, :not_running} = Poller.status(pid)
    end
  end

  test "WebSocket lifecycle and batch progress are visible without a worker mailbox call" do
    parent = self()

    state =
      FixtureHelpers.socket_state(parent,
        handler: fn _ ->
          send(parent, :handling)
          receive do: (:release -> :ok)
        end
      )

    state =
      ExironClient.RuntimeStatus.attach(%{
        state
        | connected?: false,
          connection_state: :disconnected
      })

    worker =
      start_supervised!(%{
        id: SocketWorker,
        start: {SocketWorker, :start_link, [self(), state.handler, state.handler_options]}
      })

    state = %{state | worker_pid: worker, worker_monitor_ref: Process.monitor(worker)}
    {:ok, state} = SocketPoller.handle_connect(nil, state)

    {:ok, state} =
      SocketPoller.handle_frame(
        {:text, Jason.encode!(FixtureHelpers.contract_json("websocket_connected_frame.json"))},
        state
      )

    assert {:ok, %{phase: :waiting, connected?: true}} = Poller.status(self())

    {:ok, state} =
      SocketPoller.handle_frame(
        {:text, FixtureHelpers.websocket_messages_frame("private-request", "private-content")},
        state
      )

    assert_receive :handling

    assert {:ok, %{phase: :handling, active_handlers: 1, batch_size: 1} = status} =
             Poller.status(self())

    refute inspect(status) =~ "private-"
    send(worker, :release)
    assert_receive {:handler_complete, ^worker, job}
    {:reply, _, _state} = SocketPoller.handle_info({:handler_complete, worker, job}, state)

    assert {:ok, %{phase: :waiting, active_handlers: 0, batch_completed: 1}} =
             Poller.status(self())
  end

  test "WebSocket backoff remains readable while the reconnect sleep is blocked" do
    parent = self()

    client =
      FixtureHelpers.socket_client(
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 1000,
          max_delay_ms: 1000,
          max_retry_time_ms: 5000,
          sleep: fn _ ->
            send(parent, {:backing_off, self()})
            receive do: (:release -> :ok)
          end
        ]
      )

    task =
      start_supervised!(
        {Task,
         fn ->
           state = FixtureHelpers.socket_state(parent, client: client, handler: fn _ -> :ok end)
           SocketPoller.handle_disconnect(%{reason: :closed}, state)
         end},
        restart: :temporary
      )

    ref = Process.monitor(task)
    assert_receive {:backing_off, ^task}, 1000
    assert {:ok, status} = Poller.status(task)
    assert status.phase == :backing_off
    refute status.connected?
    assert status.retry_in_ms > 0
    assert is_integer(status.retry_at)
    assert status.last_error.kind == :transport_error
    send(task, :release)
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
    assert {:error, :not_running} = Poller.status(task)
  end

  test "handler failure summaries omit arbitrary reasons while retry callbacks block" do
    parent = self()

    pid =
      start_supervised!(
        {Poller,
         client: client(),
         transport: :http,
         handler_max_attempts: 2,
         handler: fn _ -> {:error, "private-handler-content"} end,
         on_handler_error: fn _ ->
           send(parent, :failed)
           receive do: (:release -> :ok)
         end}
      )

    assert_receive :failed
    assert {:ok, status} = Poller.status(pid)
    assert status.last_error.kind == :handler_error
    assert status.active_handlers == 1
    refute inspect(status) =~ "private-"
    stop_supervised!(Poller)
  end

  defp client do
    ExironClient.new(
      base_url: "http://exiron.test",
      token: "private-token",
      client_id: "private-client",
      req_options: [
        adapter: fn req ->
          body =
            case req.url.path do
              "/api/capabilities" ->
                %{
                  protocol_version: "1.16",
                  capabilities: ["client_retirement", "http_lease_renewal"]
                }

              "/api/requests" ->
                %{
                  delivery_id: "private-batch",
                  requests:
                    for(
                      id <- 1..2,
                      do: %{
                        msgtype: "request",
                        req_id: "req-#{id}",
                        datatype: "text",
                        data: Base.encode64("private-content")
                      }
                    )
                }

              "/api/client-lease" ->
                %{ok: true, lease_timeout_ms: 10000}

              "/api/client-retire" ->
                %{ok: true}
            end

          {req, Req.Response.json(body)}
        end
      ]
    )
  end
end
