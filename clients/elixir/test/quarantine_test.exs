defmodule ExironClient.QuarantineTest do
  use ExUnit.Case, async: true

  alias ExironClient.{
    Quarantine,
    MessageHandler,
    Message,
    Poller,
    SocketPoller,
    SocketWorker,
    FixtureHelpers
  }

  for concurrency <- [1, 3], ordered <- [false, true] do
    @concurrency concurrency
    @ordered ordered
    test "quarantine continues healthy work with concurrency=#{concurrency}, ordered=#{ordered}" do
      parent = self()
      store = start_supervised!({Quarantine, []})

      handler = fn message ->
        send(parent, {:handled, message.req_id})
        if message.req_id == "bad", do: {:error, "private-error"}, else: :ok
      end

      assert :ok =
               MessageHandler.handle(messages(), handler,
                 failure_policy: :quarantine,
                 quarantine: store,
                 concurrency: @concurrency,
                 order_by_chat: @ordered,
                 max_attempts: 2,
                 wait: fn _ -> :ok end,
                 on_quarantined: fn metadata -> send(parent, {:quarantined, metadata}) end
               )

      assert_receive {:quarantined, %{request_id: "bad", attempts: 2} = entry}
      assert_receive {:handled, "bad"}
      assert_receive {:handled, "bad"}
      assert_receive {:handled, "good"}
      assert_receive {:handled, "other"}
      assert {:ok, %{count: 1, bytes: bytes}} = Quarantine.stats(store)
      assert bytes > 0
      refute inspect(entry) =~ "private-error"

      assert :ok =
               Quarantine.recover(store, entry.id, fn message ->
                 assert message.req_id == "bad"
                 assert message.data == "private-content"
                 :ok
               end)

      assert {:ok, %{count: 0, bytes: 0}} = Quarantine.stats(store)
    end
  end

  test "full and oversized stores retain previous work and stop dispatch" do
    parent = self()
    store = start_supervised!({Quarantine, max_messages: 1})

    handler = fn message ->
      send(parent, {:handled, message.req_id})
      {:error, :failed}
    end

    assert {:error, {:quarantine_failed, :quarantine_full, :failed}} =
             MessageHandler.handle(messages(), handler,
               failure_policy: :quarantine,
               quarantine: store
             )

    assert_receive {:handled, "bad"}
    assert_receive {:handled, "good"}
    refute_received {:handled, "other"}
    assert {:ok, [entry]} = Quarantine.entries(store)
    assert entry.request_id == "bad"
    small = start_supervised!({Quarantine, max_bytes: entry.bytes - 1}, id: make_ref())

    assert {:error, {:quarantine_failed, :quarantine_full, :failed}} =
             MessageHandler.handle([hd(messages())], handler,
               failure_policy: :quarantine,
               quarantine: small
             )

    assert {:ok, %{count: 0, bytes: 0}} = Quarantine.stats(small)
    # Successful work can proceed even when the supplied store is full.
    assert :ok =
             MessageHandler.handle(messages(), fn _ -> :ok end,
               failure_policy: :quarantine,
               quarantine: store
             )

    assert {:ok, [^entry]} = Quarantine.entries(store)
  end

  test "concurrent producers cannot exceed count or byte limits" do
    store = start_supervised!({Quarantine, max_messages: 3})
    repeated = List.duplicate(hd(messages()), 30)
    handler = fn _ -> {:error, :failed} end
    opts = [failure_policy: :quarantine, quarantine: store, concurrency: 8]

    assert {:error, {:quarantine_failed, :quarantine_full, :failed}} =
             MessageHandler.handle(repeated, handler, opts)

    assert {:ok, %{count: 3, bytes: bytes}} = Quarantine.stats(store)
    small = start_supervised!({Quarantine, max_bytes: div(bytes, 3) * 2}, id: make_ref())

    assert {:error, {:quarantine_failed, :quarantine_full, :failed}} =
             MessageHandler.handle(repeated, handler, Keyword.put(opts, :quarantine, small))

    assert {:ok, %{count: 2, bytes: used, max_bytes: limit}} = Quarantine.stats(small)
    assert used <= limit
  end

  test "recovery errors and exceptions retain entries and never expose payloads in metadata or OTP status" do
    store = start_supervised!({Quarantine, []})

    message = %{
      hd(messages())
      | media_items: [%ExironClient.MediaItem{datatype: "photo", data: "private-file"}],
        caption: "private-caption"
    }

    assert :ok =
             MessageHandler.handle([message], fn _ -> {:error, "private-error"} end,
               failure_policy: :quarantine,
               quarantine: store
             )

    assert {:ok, [entry]} = Quarantine.entries(store)
    refute inspect(entry) =~ "private-"
    refute inspect(:sys.get_status(store)) =~ "private-"

    assert {:error, :retry_later} =
             Quarantine.recover(store, entry.id, fn received ->
               assert received == message
               {:error, :retry_later}
             end)

    assert {:error, %RuntimeError{}} =
             Quarantine.recover(store, entry.id, fn _ -> raise "private-exception" end)

    assert {:error, :invalid_recovery_result} =
             Quarantine.recover(store, entry.id, fn _ -> :wrong end)

    assert {:ok, %{count: 1, recovering: 0}} = Quarantine.stats(store)

    assert :ok =
             Quarantine.recover(store, entry.id, fn received ->
               assert received == message
               :ok
             end)

    assert {:error, :quarantine_not_found} =
             Quarantine.recover(store, entry.id, fn _ -> flunk("missing callback ran") end)
  end

  test "a recovery claim holds capacity, rejects concurrent recovery and is released on caller death" do
    parent = self()
    store = start_supervised!({Quarantine, max_messages: 1})
    opts = [failure_policy: :quarantine, quarantine: store]
    assert :ok = MessageHandler.handle([hd(messages())], fn _ -> {:error, :bad} end, opts)
    assert {:ok, [entry]} = Quarantine.entries(store)

    task =
      start_supervised!(
        {Task,
         fn ->
           Quarantine.recover(store, entry.id, fn _ ->
             send(parent, :recovering)
             receive do: (:release -> :ok)
           end)
         end},
        restart: :temporary
      )

    ref = Process.monitor(task)
    assert_receive :recovering
    assert {:ok, %{count: 1, recovering: 1}} = Quarantine.stats(store)

    assert {:error, :quarantine_busy} =
             Quarantine.recover(store, entry.id, fn _ -> flunk("duplicate callback ran") end)

    assert {:error, {:quarantine_failed, :quarantine_full, :bad}} =
             MessageHandler.handle([hd(messages())], fn _ -> {:error, :bad} end, opts)

    Process.exit(task, :kill)
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}
    _ = :sys.get_state(store)
    assert {:ok, %{count: 1, recovering: 0}} = Quarantine.stats(store)
    assert :ok = Quarantine.recover(store, entry.id, fn _ -> :ok end)
  end

  test "stop remains the default; lease loss and confirmed cancellation are not quarantined" do
    store = start_supervised!({Quarantine, []})

    assert {:error, :bad} =
             MessageHandler.handle(messages(), fn _ -> {:error, :bad} end, quarantine: store)

    opts = [failure_policy: :quarantine, quarantine: store]

    assert {:error, %ExironClient.Error{reason: :client_lease_lost}} =
             MessageHandler.handle(
               messages(),
               fn _ -> {:error, ExironClient.Lease.error()} end,
               opts
             )

    assert :ok =
             MessageHandler.handle(
               messages(),
               fn _ -> {:error, ExironClient.Error.new(:request_cancelled, "cancelled")} end,
               opts
             )

    assert {:ok, %{count: 0}} = Quarantine.stats(store)

    assert_raise ArgumentError, fn ->
      ExironClient.PollerOptions.build!(
        client: client(self()),
        handler: fn _ -> :ok end,
        handler_failure_policy: :quarantine
      )
    end

    assert_raise ArgumentError, fn ->
      ExironClient.PollerOptions.build!(
        client: client(self()),
        handler: fn _ -> :ok end,
        handler_failure_policy: :unknown
      )
    end

    assert_raise ArgumentError, fn -> Quarantine.start_link(max_messages: 0) end
    stop_supervised!(Quarantine)

    assert {:error, {:quarantine_failed, :quarantine_unavailable, :bad}} =
             MessageHandler.handle(messages(), fn _ -> {:error, :bad} end, opts)
  end

  for graceful <- [false, true] do
    @graceful graceful
    test "HTTP acknowledgement waits for healthy streaming work (graceful=#{graceful})" do
      parent = self()
      store = start_supervised!({Quarantine, []})
      client = client(parent)
      id = make_ref()

      pid =
        start_supervised!(%{
          id: id,
          restart: :temporary,
          start:
            {Poller, :start_link,
             [
               [
                 client: client,
                 transport: :http,
                 interval_ms: 10,
                 graceful_shutdown: @graceful,
                 handler_failure_policy: :quarantine,
                 quarantine: store,
                 on_quarantined: fn meta -> send(parent, {:quarantined, meta}) end,
                 handler: fn message ->
                   if message.req_id == "bad" do
                     {:error, :poison}
                   else
                     send(parent, {:healthy, self()})
                     receive do: (:release -> :ok)
                     assert {:ok, _} = ExironClient.update_text(client, message, "partial")
                     assert {:ok, _} = ExironClient.reply_text(client, message, "done")
                     :ok
                   end
                 end
               ]
             ]}
        })

      monitor = Process.monitor(pid)
      assert_receive {:quarantined, _}, 1000
      assert_receive {:healthy, worker}, 1000

      assert {:ok, %{batch_quarantined: 1, quarantine: %{count: 1, available?: true}} = status} =
               Poller.status(pid)

      refute inspect(status) =~ "private-"
      refute_received :acknowledged

      if @graceful do
        ref = make_ref()
        send(pid, {:client_drain, self(), ref, ExironClient.ClientDrain.now() + 2000})
        _ = :sys.get_state(pid)
        send(worker, :release)
        assert_receive {:client_drain_result, ^ref, :ok}, 1000
        assert_receive :retired, 1000
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
        refute_received :acknowledged
      else
        send(worker, :release)
        assert_receive :acknowledged, 1000
        stop_supervised!(id)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 1000
      end

      assert_receive :response
      assert_receive :response
      assert {:ok, %{count: 1}} = Quarantine.stats(store)
      assert {:ok, [entry]} = Quarantine.entries(store)

      assert :ok =
               Quarantine.recover(store, entry.id, fn message ->
                 assert message.req_id == "bad"
                 :ok
               end)
    end
  end

  test "HTTP store exhaustion stops without acknowledging its batch and retains previous entries" do
    parent = self()
    store = start_supervised!({Quarantine, max_messages: 1})
    assert Poller.child_spec(handler_failure_policy: :quarantine).restart == :temporary
    assert Poller.child_spec([]).restart == :permanent

    ExUnit.CaptureLog.capture_log(fn ->
      pid =
        start_supervised!(
          {Poller,
           client: client(parent),
           transport: :http,
           handler_failure_policy: :quarantine,
           quarantine: store,
           handler: fn message ->
             if message.req_id == "good" do
               send(parent, {:capacity_waiting, self()})
               receive do: (:release -> :ok)
             end

             {:error, :poison}
           end}
        )

      ref = Process.monitor(pid)
      assert_receive {:capacity_waiting, ^pid}, 1000
      send(pid, :release)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:quarantine_failed, :quarantine_full, :poison}},
                     1000

      refute_received :acknowledged
      assert {:ok, [entry]} = Quarantine.entries(store)
      assert entry.request_id == "bad"
      assert :ok = Quarantine.recover(store, entry.id, fn _ -> :ok end)
    end)
  end

  test "WebSocket acknowledges after quarantine and remaining work completes" do
    parent = self()
    store = start_supervised!({Quarantine, []})

    state =
      FixtureHelpers.socket_state(parent,
        handler: fn message ->
          if message.req_id == "bad", do: {:error, :poison}, else: :ok
        end
      )

    state =
      ExironClient.RuntimeStatus.attach(%{
        state
        | handler_options: [failure_policy: :quarantine, quarantine: store]
      })

    worker =
      start_supervised!(%{
        id: SocketWorker,
        start: {SocketWorker, :start_link, [self(), state.handler, state.handler_options]}
      })

    state = %{state | worker_pid: worker, worker_monitor_ref: Process.monitor(worker)}
    payload = Jason.encode!(%{type: "messages", delivery_id: "batch", messages: wire_messages()})
    assert {:ok, state} = SocketPoller.handle_frame({:text, payload}, state)
    assert_receive {:handler_complete, ^worker, job}, 1000

    assert {:reply, {:text, frame}, _} =
             SocketPoller.handle_info({:handler_complete, worker, job}, state)

    assert Jason.decode!(frame) == %{"type" => "ack", "delivery_id" => "batch"}

    assert {:ok, %{batch_completed: 2, batch_quarantined: 1, quarantine: %{count: 1}}} =
             Poller.status(self())
  end

  defp messages do
    for {id, chat} <- [{"bad", 1}, {"good", 1}, {"other", 2}],
        do: %Message{
          req_id: id,
          msgtype: "request",
          service_id: 1,
          chat_id: chat,
          datatype: "text",
          data: "private-content"
        }
  end

  defp wire_messages do
    for id <- ["bad", "good"],
        do: %{
          msgtype: "request",
          req_id: id,
          datatype: "text",
          data: Base.encode64("private-content")
        }
  end

  defp client(parent) do
    ExironClient.new(
      base_url: "http://exiron.test",
      token: "private-token",
      client_id: "worker",
      req_options: [
        adapter: fn req ->
          body =
            case req.url.path do
              "/api/capabilities" ->
                %{
                  protocol_version: "1.16",
                  capabilities: ["client_retirement", "http_lease_renewal"]
                }

              "/api/client-lease" ->
                %{ok: true, lease_timeout_ms: 10000}

              "/api/client-retire" ->
                send(parent, :retired)
                %{ok: true}

              "/api/responses" ->
                send(parent, :response)
                %{ok: true}

              "/api/requests" ->
                if URI.decode_query(req.url.query || "")["delivery_ack"] == "batch" do
                  send(parent, :acknowledged)
                  %{requests: []}
                else
                  %{delivery_id: "batch", requests: wire_messages()}
                end
            end

          {req, Req.Response.json(body)}
        end
      ]
    )
  end
end
