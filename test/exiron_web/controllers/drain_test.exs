defmodule ExironWeb.DrainTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new(
          [%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:ok, %{message_id: 901}} end
        )
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    on_exit(fn -> Hub.resume_intake() end)
    :ok
  end

  test "drain keeps streaming and one-shot responses working and waits for acknowledgements", %{
    conn: conn
  } do
    assert :ok = incoming(1)
    assert :ok = incoming(2)

    assert {:ok, %{delivery_id: batch, requests: [one, two]}} =
             Hub.poll_delivery("ai-token", client_id: "worker")

    assert {:ok, %{phase: "draining", pending_requests: 2, unacknowledged_batches: 1}} =
             Hub.start_drain()

    assert {:retry, :draining} = incoming(3)
    assert {:retry, :draining} = Hub.incoming_callback("bot-token", %{})
    assert json_response(get(conn, "/health/ready"), 503)["reason"] == "draining"
    assert json_response(get(conn, "/health/live"), 200)["status"] == "alive"

    assert {:ok, %{final: false}} =
             Hub.respond("ai-token", one.req_id, "text", "partial", final: false)

    assert :ok = Hub.respond("ai-token", one.req_id, "text", "finished")
    assert :ok = Hub.respond("ai-token", two.req_id, "text", "one shot")
    assert %{pending_requests: 0, unacknowledged_batches: 1, drained: false} = Hub.drain_status()

    assert {:ok, %{requests: []}} =
             Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: batch)

    assert %{phase: "drained", drained: true} = Hub.drain_status()
    assert {:error, :draining} = Hub.push("ai-token", "text", "new", 123)
    assert {:error, :draining} = Hub.edit("ai-token", one.req_id, "text", "edited")
    assert :ok = Hub.resume_intake()
    assert %{ready: true} = Hub.readiness()
    assert :ok = incoming(3)
    assert %{pending_requests: 1} = Hub.drain_status()
  end

  test "WebSocket deliveries can acknowledge and reply while draining" do
    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new(
          [%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:ok, %{message_id: 902}} end
        )
      )

    assert {:ok, %{messages: []}} =
             Hub.connect_socket("ai-token", client_id: "socket", pid: self())

    :ok = incoming(1)
    assert_receive {:exiron_messages, batch, [request]}
    assert {:ok, %{unacknowledged_batches: 1, phase: "draining"}} = Hub.start_drain()
    :ok = Hub.complete_socket_delivery("assistant", "socket", self(), batch)
    assert %{unacknowledged_batches: 0, pending_requests: 1} = Hub.drain_status()
    assert :ok = Hub.respond("ai-token", request.req_id, "text", "done")
    assert %{phase: "drained"} = Hub.drain_status()
  end

  test "timeout keeps intake paused, stale timers cannot affect a later drain" do
    :ok = incoming(1)
    {:ok, _} = Hub.start_drain(timeout_ms: 60_000)
    generation = :sys.get_state(Hub).drain.generation
    send(Hub, {:drain_timeout, generation})
    assert %{phase: "timed_out", active: true, pending_requests: 1} = Hub.drain_status()
    assert {:retry, :draining} = incoming(2)
    assert {:ok, %{phase: "timed_out"}} = Hub.start_drain()
    :ok = Hub.resume_intake()
    {:ok, _} = Hub.start_drain()
    send(Hub, {:drain_timeout, generation})
    assert %{phase: "draining"} = Hub.drain_status()
    assert {:error, :invalid_payload} = Hub.start_drain(timeout_ms: 0)
  end

  test "queued listeners and active sends prevent an empty drain" do
    state = :sys.get_state(Hub)

    state = %{
      state
      | delivery: %{
          state.delivery
          | queues: %{
              "listener" => Exiron.Hub.QueueBuffer.from_items([%{msgtype: "listen"}])
            },
            sends: %{make_ref() => %{}}
        }
    }

    assert %{queued_messages: 1, active_sends: 1} = Exiron.Hub.Drain.snapshot(state)
    transition = Exiron.Hub.Drain.start(state, [])
    assert %{phase: "draining", drained: false} = Exiron.Hub.Drain.snapshot(transition.next_state)
    Process.cancel_timer(transition.next_state.drain.timer)
  end

  test "push API exposes a stable drain error without renewing client leases", %{conn: conn} do
    {:ok, _} = Hub.start_drain()

    assert conn
           |> put_req_header("authorization", "Bearer ai-token")
           |> post("/api/push", %{datatype: "text", data: Base.encode64("new"), chat_id: 123})
           |> json_response(503) == %{"code" => "draining", "error" => "intake paused for drain"}
  end

  test "an active push must finish before drain completes" do
    parent = self()

    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new(
          [%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ ->
            send(parent, {:sending, self()})

            receive do
              :finish -> {:ok, %{message_id: 901}}
            end
          end
        )
      )

    start_supervised!(
      {Task,
       fn -> send(parent, {:push_result, Hub.push("ai-token", "text", "accepted", 123)}) end},
      restart: :temporary
    )

    assert_receive {:sending, sender}
    assert {:ok, %{active_sends: 1, pending_requests: 0, phase: "draining"}} = Hub.start_drain()
    send(sender, :finish)
    assert_receive {:push_result, {:ok, 1}}
    assert %{phase: "drained", active_sends: 0} = Hub.drain_status()
  end

  @tag capture_log: true
  test "a Telegram poll already in flight cannot admit or acknowledge new work while draining" do
    parent = self()
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")

    poller =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller,
         token: "bot-token",
         get_updates: fn opts ->
           send(parent, {:telegram_poll, self(), opts})

           receive do
             :update ->
               {:ok,
                [%{update_id: 41, message: %{chat: %{id: 123}, message_id: 11, text: "/ai hi"}}]}

             :stop ->
               {:error, %ExGram.Error{code: 401}}
           end
         end}
      )

    assert_receive {:telegram_poll, ^poller, _}
    {:ok, _} = Hub.start_drain()
    send(poller, :update)
    state = :sys.get_state(poller)
    assert state.offset == 41
    assert %{pending_requests: 0} = Hub.drain_status()
    send(poller, :poll)
    _ = :sys.get_state(poller)
    refute_receive {:telegram_poll, _, _}
    :ok = Hub.resume_intake()
    send(poller, :poll)
    assert_receive {:telegram_poll, ^poller, opts}
    assert opts[:offset] == 41
    ref = Process.monitor(poller)
    send(poller, :stop)
    assert_receive {:DOWN, ^ref, :process, ^poller, :normal}
  end

  defp incoming(n) do
    Hub.incoming_service_message(
      Message.incoming(Telegram.service_id(), 123, "text", "/ai hi",
        bot_token: "bot-token",
        message_id: n
      )
    )
  end
end
