defmodule ExironClient.ClientDrainTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Error, Poller, SocketPoller, SocketWorker}
  import ExironClient.FixtureHelpers, only: [socket_state: 2]

  test "HTTP drain finishes streaming, renews its lease and retires without another poll" do
    parent = self()
    {client, requests} = client(parent)

    handler = fn message ->
      assert {:ok, _} = ExironClient.update_text(client, message, "partial")
      send(parent, {:entered, self()})
      receive do: (:release -> :ok)
      assert {:ok, _} = ExironClient.reply_text(client, message, "done")
    end

    pid =
      start_supervised!(
        {Poller,
         client: client,
         transport: :http,
         graceful_shutdown: true,
         interval_ms: 10,
         handler: handler}
      )

    monitor = Process.monitor(pid)
    assert_receive {:entered, worker}, 1000
    assert_receive {:renewed, _}, 1000
    ref = make_ref()
    send(pid, {:client_drain, self(), ref, ExironClient.ClientDrain.now() + 2000})
    original = :sys.get_state(pid).client_drain
    assert original.ref == ref
    duplicate = make_ref()
    send(pid, {:client_drain, self(), duplicate, ExironClient.ClientDrain.now() + 100})
    assert_receive {:client_drain_result, ^duplicate, {:error, :already_draining}}
    send(pid, {:client_drain_timeout, make_ref()})
    assert :sys.get_state(pid).client_drain == original
    assert_receive {:renewed, _}, 1000
    refute_received :retired
    send(worker, :release)
    assert_receive {:client_drain_result, ^ref, :ok}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
    refute_received {:client_drain_result, ^ref, _}
    calls = Agent.get(requests, & &1)
    assert Enum.count(calls, &(&1 == "/api/requests")) == 1
    assert Enum.count(calls, &(&1 == "/api/client-retire")) == 1
    assert Enum.count(calls, &(&1 == "/api/responses")) == 2
  end

  test "public drain deadline terminates the handler and never acknowledges unfinished work" do
    parent = self()
    {client, requests} = client(parent)

    pid =
      start_supervised!(
        {Poller,
         client: client,
         transport: :http,
         graceful_shutdown: true,
         interval_ms: 10,
         handler: fn _ ->
           send(parent, {:entered, self()})
           receive do: (:release -> :ok)
         end}
      )

    assert_receive {:entered, worker}, 1000
    worker_ref = Process.monitor(worker)
    assert {:error, :drain_timeout} = Poller.drain(pid, 20)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :shutdown}, 1000
    refute "/api/client-retire" in Agent.get(requests, & &1)
  end

  test "public idle drain stops even while a poll transport is blocked" do
    parent = self()

    {client, _requests} =
      client(parent,
        poll: fn req ->
          send(parent, :polling)
          receive do: (:release -> {req, Req.Response.json(%{requests: []})})
        end
      )

    pid =
      start_supervised!(
        {Poller,
         client: client,
         transport: :http,
         graceful_shutdown: true,
         interval_ms: 10,
         handler: fn _ -> flunk("idle handler ran") end}
      )

    assert_receive :polling, 1000
    assert :ok = Poller.drain(pid, 200)
    refute_received :retired
  end

  test "retirement errors are surfaced without another fetch or acknowledgement retry" do
    parent = self()
    {client, requests} = client(parent, retire_status: 409)

    pid =
      start_supervised!(
        {Poller,
         client: client,
         transport: :http,
         graceful_shutdown: true,
         interval_ms: 10,
         handler: fn _ ->
           send(parent, {:entered, self()})
           receive do: (:release -> :ok)
         end}
      )

    assert_receive {:entered, worker}, 1000
    ref = make_ref()
    send(pid, {:client_drain, self(), ref, ExironClient.ClientDrain.now() + 1000})
    _ = :sys.get_state(pid)
    send(worker, :release)
    assert_receive {:client_drain_result, ^ref, {:error, %Error{status: 409}}}, 1000
    assert Enum.count(Agent.get(requests, & &1), &(&1 == "/api/client-retire")) == 1
    assert Enum.count(Agent.get(requests, & &1), &(&1 == "/api/requests")) == 1
  end

  test "unsupported retirement fails option negotiation before consuming work" do
    {client, requests} = client(self(), capabilities: ["http_lease_renewal"])

    assert_raise ArgumentError, "server does not support client_retirement", fn ->
      ExironClient.PollerOptions.build!(
        client: client,
        transport: :http,
        graceful_shutdown: true,
        handler: fn _ -> :ok end
      )
    end

    assert Agent.get(requests, & &1) == ["/api/capabilities"]
  end

  test "HTTP handler failure during drain reports failure and leaves the batch unacknowledged" do
    parent = self()
    {client, requests} = client(parent)

    pid =
      start_supervised!(
        {Poller,
         client: client,
         transport: :http,
         graceful_shutdown: true,
         interval_ms: 10,
         handler: fn _ ->
           send(parent, {:entered, self()})
           receive do: (:release -> {:error, :handler_failed})
         end}
      )

    monitor = Process.monitor(pid)
    assert_receive {:entered, worker}, 1000
    worker_monitor = Process.monitor(worker)
    ref = make_ref()
    send(pid, {:client_drain, self(), ref, ExironClient.ClientDrain.now() + 2000})
    assert :sys.get_state(pid).client_drain.ref == ref
    send(worker, :release)
    assert_receive {:client_drain_result, ^ref, {:error, :handler_failed}}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1000
    refute_received {:client_drain_result, ^ref, _}
    calls = Agent.get(requests, & &1)
    assert Enum.count(calls, &(&1 == "/api/requests")) == 1
    refute "/api/client-retire" in calls
  end

  test "WebSocket drain keeps pings and confirms retirement instead of returning an ack frame" do
    parent = self()

    {client, requests} =
      client(parent,
        retire: fn req ->
          send(parent, {:retirement_waiting, self()})
          receive do: (:release_retirement -> {req, Req.Response.json(%{ok: true})})
        end
      )

    handler = fn _ ->
      send(parent, :handling)
      receive do: (:release -> :ok)
    end

    worker =
      start_supervised!(%{
        id: make_ref(),
        start: {SocketWorker, :start_link, [self(), handler, []]},
        restart: :temporary
      })

    state = socket_state(parent, client: client, handler: handler)

    state = %{
      state
      | graceful_shutdown: true,
        worker_pid: worker,
        worker_monitor_ref: Process.monitor(worker),
        disconnect_timeout_ms: 10000
    }

    frame = ExironClient.FixtureHelpers.websocket_messages_frame("req-1", "hello")
    {:ok, state} = SocketPoller.handle_frame({:text, frame}, state)
    assert_receive :handling
    ref = make_ref()

    {:ok, state} =
      SocketPoller.handle_info(
        {:client_drain, self(), ref, ExironClient.ClientDrain.now() + 2000},
        state
      )

    original = state.client_drain
    duplicate = make_ref()

    assert {:ok, ^state} =
             SocketPoller.handle_info(
               {:client_drain, self(), duplicate, ExironClient.ClientDrain.now() + 100},
               state
             )

    assert_receive {:client_drain_result, ^duplicate, {:error, :already_draining}}
    assert {:ok, ^state} = SocketPoller.handle_info({:client_drain_timeout, make_ref()}, state)
    assert state.client_drain == original

    assert {:ok, ^state} =
             SocketPoller.handle_info({:handler_complete, worker, make_ref()}, state)

    assert {:ok, ^state} =
             SocketPoller.handle_info(
               {:handler_failed, worker, make_ref(), :stale_failure},
               state
             )

    ping = make_ref()

    assert {:reply, {:text, ping_frame}, _} =
             SocketPoller.handle_info({:ping, ping}, %{state | ping_ref: ping})

    assert Jason.decode!(ping_frame)["type"] == "ping"
    refute_received :retired
    send(worker, :release)
    assert_receive {:handler_complete, ^worker, job_ref}, 1000

    assert {:ok, retiring} = SocketPoller.handle_info({:handler_complete, worker, job_ref}, state)
    task_ref = retiring.retire_task.ref
    assert_receive {:retirement_waiting, control}, 1000
    ping_ref = make_ref()

    assert {:reply, {:text, _ping}, _} =
             SocketPoller.handle_info({:ping, ping_ref}, %{retiring | ping_ref: ping_ref})

    send(control, :release_retirement)
    assert_receive {^task_ref, :ok}, 1000

    assert {:close, {1000, "drained"}, final} =
             SocketPoller.handle_info({task_ref, :ok}, retiring)

    assert_receive {:client_drain_result, ^ref, :ok}
    assert Agent.get(requests, & &1) == ["/api/client-retire"]

    assert :normal =
             catch_exit(
               SocketPoller.handle_disconnect(%{reason: {:local, 1000, "drained"}}, final)
             )

    refute_received {:client_drain_result, ^ref, _}
    assert :ok = SocketPoller.terminate(:normal, final)
  end

  test "WebSocket handler failure during drain reports failure without retirement or acknowledgement" do
    parent = self()
    {client, requests} = client(parent)

    handler = fn _ ->
      send(parent, :handling)
      receive do: (:release -> {:error, :handler_failed})
    end

    worker =
      start_supervised!(%{
        id: make_ref(),
        start: {SocketWorker, :start_link, [self(), handler, []]},
        restart: :temporary
      })

    state = socket_state(parent, client: client, handler: handler)

    state = %{
      state
      | graceful_shutdown: true,
        worker_pid: worker,
        worker_monitor_ref: Process.monitor(worker)
    }

    worker_monitor = Process.monitor(worker)
    frame = ExironClient.FixtureHelpers.websocket_messages_frame("req-1", "hello")
    {:ok, state} = SocketPoller.handle_frame({:text, frame}, state)
    assert_receive :handling
    ref = make_ref()

    {:ok, state} =
      SocketPoller.handle_info(
        {:client_drain, self(), ref, ExironClient.ClientDrain.now() + 2000},
        state
      )

    send(worker, :release)
    assert_receive {:handler_failed, ^worker, job_ref, :handler_failed}, 1000

    assert :normal =
             catch_exit(
               SocketPoller.handle_info(
                 {:handler_failed, worker, job_ref, :handler_failed},
                 state
               )
             )

    assert_receive {:client_drain_result, ^ref, {:error, :handler_failed}}
    assert_receive {:disconnected, :handler_failed}
    assert :ok = SocketPoller.terminate(:normal, state)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1000
    refute_received {:client_drain_result, ^ref, _}
    assert Agent.get(requests, & &1) == []
  end

  defp client(parent, overrides \\ []) do
    requests = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        client_id: "worker",
        req_options: [
          adapter: fn req ->
            Agent.update(requests, &(&1 ++ [req.url.path]))

            case req.url.path do
              "/api/capabilities" ->
                {req,
                 Req.Response.json(%{
                   protocol_version: "1.16",
                   capabilities:
                     Keyword.get(overrides, :capabilities, [
                       "client_retirement",
                       "http_lease_renewal"
                     ])
                 })}

              "/api/requests" ->
                if poll = overrides[:poll],
                  do: poll.(req),
                  else:
                    {req,
                     Req.Response.json(%{
                       delivery_id: "batch-1",
                       requests: [
                         %{
                           msgtype: "request",
                           req_id: "req-1",
                           datatype: "text",
                           data: Base.encode64("hello")
                         }
                       ]
                     })}

              "/api/client-lease" ->
                send(parent, {:renewed, self()})
                {req, Req.Response.json(%{ok: true, lease_timeout_ms: 300})}

              "/api/responses" ->
                {req, Req.Response.json(%{ok: true})}

              "/api/client-retire" ->
                send(parent, :retired)

                if custom = overrides[:retire] do
                  custom.(req)
                else
                  if overrides[:retire_status],
                    do:
                      {req,
                       %Req.Response{
                         status: overrides[:retire_status],
                         body: %{"error" => "lost", "code" => "client_lease_lost"}
                       }},
                    else: {req, Req.Response.json(%{ok: true})}
                end
            end
          end
        ]
      )

    {client, requests}
  end
end
