defmodule ExironClient.HandlerDeadlineTest do
  use ExUnit.Case, async: true
  alias ExironClient.{HandlerDeadline, MessageHandler, Message, Poller, Quarantine, Error}

  test "overdue serial handler keeps its slot and late success is neither acknowledged nor quarantined" do
    parent = self()
    store = start_supervised!({Quarantine, []})

    task =
      batch_task(
        [handler_timeout_ms: 40, failure_policy: :quarantine, quarantine: store],
        fn message ->
          token = HandlerDeadline.current()
          send(parent, {:started, message.req_id, token})
          ref = token.ref
          receive do: ({:exiron_handler_deadline, ^ref} -> :ok)
          send(parent, {:overdue, self()})
          receive do: (:release -> :ok)
        end
      )

    ref = Process.monitor(task)
    assert_receive {:started, "one", token}, 1000
    assert_receive {:overdue, ^task}, 1000
    assert HandlerDeadline.expired?(token)
    assert HandlerDeadline.remaining_ms(token) == 0

    assert {:ok,
            %{active_handlers: 1, overdue_handlers: 1, batch_timed_out: 1, handler_timeout_ms: 40}} =
             Poller.status(task)

    refute_received {:batch_result, _, _}
    refute_received {:started, "two", _}
    send(task, :release)

    assert_receive {:batch_result, {:error, %Error{reason: :handler_deadline_exceeded}},
                    {:ok, status}},
                   1000

    assert status.active_handlers == 0
    assert status.overdue_handlers == 0
    assert status.batch_completed == 0
    assert status.batch_timed_out == 1
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
    assert {:ok, %{count: 0}} = Quarantine.stats(store)
  end

  for ordered <- [false, true] do
    @ordered ordered
    test "concurrent overdue handlers remain owned and queued dispatch stops (ordered=#{ordered})" do
      parent = self()

      task =
        batch_task(
          [handler_timeout_ms: 40, concurrency: 2, order_by_chat: @ordered],
          fn message ->
            send(parent, {:started, message.req_id})
            token = HandlerDeadline.current()
            ref = token.ref
            receive do: ({:exiron_handler_deadline, ^ref} -> :ok)
            send(parent, {:overdue, message.req_id, self()})
            receive do: (:release -> :ok)
          end
        )

      assert_receive {:overdue, first, first_pid}, 1000
      assert_receive {:overdue, second, second_pid}, 1000
      assert Enum.sort([first, second]) == ["one", "two"]
      assert {:ok, %{active_handlers: 2, overdue_handlers: 2}} = Poller.status(task)
      send(first_pid, :release)
      refute_receive {:batch_result, _, _}, 20
      refute_received {:started, "queued"}
      send(second_pid, :release)

      assert_receive {:batch_result, {:error, %Error{reason: :handler_deadline_exceeded}},
                      {:ok, status}},
                     1000

      assert status.active_handlers == 0
      assert status.batch_timed_out == 2
      refute_received {:started, "queued"}
    end
  end

  test "one budget covers retry waits and blocks quarantine after a slow error callback" do
    parent = self()
    store = start_supervised!({Quarantine, []})

    handler = fn _ ->
      send(parent, :attempt)
      {:error, :failed}
    end

    batch_task([handler_timeout_ms: 30, max_attempts: 5, retry_delay_ms: 1000], handler)
    assert_receive {:batch_result, {:error, %Error{reason: :handler_deadline_exceeded}}, _}, 1000
    assert_receive :attempt
    refute_received :attempt

    batch_task(
      [
        handler_timeout_ms: 30,
        failure_policy: :quarantine,
        quarantine: store,
        on_error: fn _ ->
          ref = HandlerDeadline.current().ref
          receive do: ({:exiron_handler_deadline, ^ref} -> :ok)
        end
      ],
      handler
    )

    assert_receive {:batch_result, {:error, %Error{reason: :handler_deadline_exceeded}}, _}, 1000
    assert {:ok, %{count: 0}} = Quarantine.stats(store)
  end

  test "successful retries share their deadline and clean up tokens and notifications" do
    opts = [
      handler_timeout_ms: 1000,
      max_attempts: 2,
      wait: fn _ -> :ok end,
      on_error: fn _ -> Process.put(:retried, true) end
    ]

    assert :ok =
             MessageHandler.handle(
               [hd(messages())],
               fn _ ->
                 token = HandlerDeadline.current()

                 if Process.get(:retried) do
                   assert token == Process.get(:saved_budget)
                   :ok
                 else
                   Process.put(:saved_budget, token)
                   {:error, :retry}
                 end
               end,
               opts
             )

    token = Process.get(:saved_budget)
    refute HandlerDeadline.expired?(token)
    assert HandlerDeadline.remaining_ms(token) == nil
    assert HandlerDeadline.current() == nil
    refute_received {:exiron_handler_deadline, _}

    assert :ok =
             MessageHandler.handle([hd(messages())], fn _ ->
               assert HandlerDeadline.current() == nil
               :ok
             end)
  end

  for graceful <- [false, true] do
    @graceful graceful
    test "HTTP streaming expiry sends no final reply or batch acknowledgement (graceful=#{graceful})" do
      parent = self()
      calls = start_supervised!({Agent, fn -> [] end})

      client =
        client(fn req ->
          Agent.update(calls, &[{req.url.path, req.options[:json]} | &1])

          body =
            case req.url.path do
              "/api/capabilities" ->
                %{
                  protocol_version: "1.16",
                  capabilities: ["client_retirement", "http_lease_renewal"]
                }

              "/api/client-lease" ->
                %{ok: true, lease_timeout_ms: 10000}

              "/api/requests" ->
                %{
                  delivery_id: "batch",
                  requests: [
                    %{
                      msgtype: "request",
                      req_id: "private-request",
                      datatype: "text",
                      data: Base.encode64("private-data")
                    }
                  ]
                }

              "/api/responses" ->
                %{ok: true}

              "/api/client-retire" ->
                %{ok: true}
            end

          {req, Req.Response.json(body)}
        end)

      ExUnit.CaptureLog.capture_log(fn ->
        pid =
          start_supervised!(%{
            id: make_ref(),
            restart: :temporary,
            start:
              {Poller, :start_link,
               [
                 [
                   client: client,
                   transport: :http,
                   graceful_shutdown: @graceful,
                   interval_ms: 10,
                   handler_timeout_ms: 500,
                   handler: fn message ->
                     chunks =
                       Stream.resource(
                         fn -> 0 end,
                         fn
                           0 ->
                             {["partial"], 1}

                           1 ->
                             ref = HandlerDeadline.current().ref
                             receive do: ({:exiron_handler_deadline, ^ref} -> :ok)
                             send(parent, {:overdue, self()})
                             receive do: (:release -> :ok)
                             {["late"], 2}

                           _ ->
                             {:halt, 2}
                         end,
                         fn _ -> :ok end
                       )

                     assert {:error, %Error{reason: :handler_deadline_exceeded}} =
                              ExironClient.stream_text(client, message, chunks, interval_ms: 0)

                     # A late success still must not acknowledge the batch.
                     :ok
                   end
                 ]
               ]}
          })

        ref = Process.monitor(pid)
        assert_receive {:overdue, worker}, 1000
        assert {:ok, %{active_handlers: 1, overdue_handlers: 1} = status} = Poller.status(pid)
        refute inspect(status) =~ "private-"

        drain_ref =
          if @graceful do
            drain_ref = make_ref()
            send(pid, {:client_drain, self(), drain_ref, ExironClient.ClientDrain.now() + 2000})
            _ = :sys.get_state(pid)
            drain_ref
          end

        send(worker, :release)

        if @graceful do
          assert_receive {:client_drain_result, ^drain_ref,
                          {:error, %Error{reason: :handler_deadline_exceeded}}},
                         1000

          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
        else
          assert_receive {:DOWN, ^ref, :process, ^pid,
                          %Error{reason: :handler_deadline_exceeded}},
                         1000
        end

        recorded = Agent.get(calls, & &1)
        assert Enum.count(recorded, fn {path, _} -> path == "/api/requests" end) == 1
        assert Enum.count(recorded, fn {path, _} -> path == "/api/responses" end) == 1

        refute Enum.any?(recorded, fn {path, body} ->
                 path == "/api/client-retire" or (is_map(body) and body[:final] == true)
               end)
      end)
    end
  end

  test "WebSocket deadline keeps ownership until the worker returns and produces no ack" do
    parent = self()

    state =
      ExironClient.FixtureHelpers.socket_state(parent,
        handler: fn _ ->
          ref = HandlerDeadline.current().ref
          receive do: ({:exiron_handler_deadline, ^ref} -> :ok)
          send(parent, :overdue)
          receive do: (:release -> :ok)
        end
      )

    state =
      ExironClient.RuntimeStatus.attach(%{state | handler_options: [handler_timeout_ms: 40]})

    worker =
      start_supervised!(%{
        id: ExironClient.SocketWorker,
        start:
          {ExironClient.SocketWorker, :start_link, [self(), state.handler, state.handler_options]}
      })

    state = %{state | worker_pid: worker, worker_monitor_ref: Process.monitor(worker)}

    frame =
      ExironClient.FixtureHelpers.websocket_messages_frame("private-request", "private-text")

    assert {:ok, state} = ExironClient.SocketPoller.handle_frame({:text, frame}, state)
    assert_receive :overdue, 1000
    assert {:ok, %{active_handlers: 1, overdue_handlers: 1}} = Poller.status(self())
    refute_received {:handler_failed, _, _, _}
    send(worker, :release)

    assert_receive {:handler_failed, ^worker, job,
                    %Error{reason: :handler_deadline_exceeded} = error},
                   1000

    assert %Error{reason: :handler_deadline_exceeded} =
             catch_exit(
               ExironClient.SocketPoller.handle_info({:handler_failed, worker, job, error}, state)
             )

    assert {:ok, %{active_handlers: 0, overdue_handlers: 0, batch_timed_out: 1}} =
             Poller.status(self())
  end

  for finch <- [false, true] do
    @finch finch
    test "request budgets bound timeouts and suppress transport retry after expiry (finch=#{finch})" do
      parent = self()

      options =
        if @finch, do: [finch: :unused_custom_pool], else: [connect_options: [timeout: 321]]

      client =
        client(
          fn req ->
            send(parent, {:request_options, req.options})
            ref = HandlerDeadline.current().ref
            receive do: ({:exiron_handler_deadline, ^ref} -> :ok)
            {req, %Req.TransportError{reason: :econnrefused}}
          end,
          options
        )

      batch_task([handler_timeout_ms: 150], fn _ -> ExironClient.status(client) end)
      assert_receive {:request_options, opts}, 1000
      assert opts[:receive_timeout] <= 150
      assert opts[:pool_timeout] <= 150

      if @finch do
        refute Keyword.has_key?(opts[:connect_options] || [], :timeout)
      else
        assert opts[:connect_options][:timeout] == 321
      end

      assert_receive {:batch_result, {:error, %Error{reason: :handler_deadline_exceeded}}, _},
                     1000

      refute_received {:request_options, _}
    end
  end

  test "retry hints beyond the handler budget expire without retrying early" do
    parent = self()

    client =
      client(fn req ->
        send(parent, :request)
        {req, %Req.Response{status: 429, body: %{"error" => "busy", "retry_after_ms" => 1000}}}
      end)

    batch_task([handler_timeout_ms: 150], fn _ -> ExironClient.status(client) end)
    assert_receive {:batch_result, {:error, %Error{reason: :handler_deadline_exceeded}}, _}, 1000
    assert_receive :request
    refute_received :request
  end

  test "confirmed server cancellation remains a completed skip within a local budget" do
    client =
      client(fn req ->
        assert req.url.path == "/api/request-state"
        {req, Req.Response.json(%{req_id: "one", state: "cancelled"})}
      end)

    state =
      ExironClient.RuntimeStatus.attach(%{
        handler_options: [
          handler_timeout_ms: 1000,
          cancellation_client: client,
          cancellation_interval_ms: 100
        ]
      })

    assert :ok =
             MessageHandler.handle(
               [hd(messages())],
               fn _ -> flunk("cancelled handler ran") end,
               state.handler_options
             )

    assert {:ok,
            %{active_handlers: 0, overdue_handlers: 0, batch_timed_out: 0, batch_completed: 1}} =
             Poller.status(self())

    assert HandlerDeadline.current() == nil
  end

  test "server cancellation during a capped retry wait does not masquerade as a local timeout" do
    parent = self()
    checks = start_supervised!({Agent, fn -> 0 end})

    client =
      client(fn req ->
        case req.url.path do
          "/api/request-state" ->
            n = Agent.get_and_update(checks, fn n -> {n + 1, n + 1} end)
            id = URI.decode_query(req.url.query)["req_id"]

            {req,
             Req.Response.json(%{req_id: id, state: if(n == 1, do: "active", else: "cancelled")})}

          "/api/status" ->
            {req,
             %Req.Response{status: 429, body: %{"error" => "busy", "retry_after_ms" => 2000}}}
        end
      end)

    batch_task(
      [handler_timeout_ms: 1000, cancellation_client: client, cancellation_interval_ms: 100],
      fn _ ->
        result = ExironClient.status(client)
        send(parent, {:request_result, result})
        result
      end
    )

    assert_receive {:request_result, {:error, %Error{reason: :request_cancelled}}}, 1500
    assert_receive {:batch_result, :ok, {:ok, %{batch_timed_out: 0, overdue_handlers: 0}}}, 1500
  end

  test "invalid budgets fail local validation and lease failures remain distinct" do
    for timeout <- [-1, nil, :infinity, 1.5] do
      assert_raise ArgumentError, fn ->
        ExironClient.PollerOptions.build!(
          client: client(fn _ -> flunk("validation made a network call") end),
          handler: fn _ -> :ok end,
          handler_timeout_ms: timeout
        )
      end
    end

    assert {:error, %Error{reason: :client_lease_lost}} =
             MessageHandler.handle(
               [hd(messages())],
               fn _ -> {:error, ExironClient.Lease.error()} end,
               handler_timeout_ms: 1000
             )

    assert Error.handler_deadline_exceeded?(HandlerDeadline.error())
    refute Error.handler_deadline_exceeded?(ExironClient.Lease.error())
  end

  defp batch_task(opts, handler) do
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         state = ExironClient.RuntimeStatus.attach(%{handler_options: opts})
         result = MessageHandler.handle(messages(), handler, state.handler_options)
         send(parent, {:batch_result, result, Poller.status(self())})
       end},
      id: make_ref(),
      restart: :temporary
    )
  end

  defp messages do
    for {id, chat} <- [{"one", 1}, {"two", 2}, {"queued", 3}],
        do: %Message{
          req_id: id,
          msgtype: "request",
          datatype: "text",
          data: "private-data",
          service_id: 1,
          chat_id: chat
        }
  end

  defp client(adapter, opts \\ []) do
    ExironClient.new(
      base_url: "http://exiron.test",
      token: "private-token",
      client_id: "worker",
      req_options: [adapter: adapter] ++ opts
    )
  end
end
