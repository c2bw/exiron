defmodule Exiron.Hub.RequestCancellationTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    router = load_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "other", Exiron.Hub.HookToken.hash("other-token"))
    }

    parent = self()

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _, message ->
          send(parent, {:sent, message})
          {:ok, %{message_id: message.edit_message_id || 901}}
        end
      )

    :ok = Hub.configure(router, telegram)
    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "cancel is owned, idempotent and terminal for all request operations" do
    req = request()
    assert {:error, :request_not_assigned} = Hub.cancel("other-token", req.req_id)
    assert {:error, :invalid_token} = Hub.cancel("wrong", req.req_id)

    assert {:ok, %{delivery_status: "not_started", message_ids: []} = result} =
             Hub.cancel("ai-token", req.req_id)

    assert {:ok, ^result} = Hub.cancel("ai-token", req.req_id)
    assert {:error, :request_not_assigned} = Hub.cancel("other-token", req.req_id)
    assert {:error, :request_cancelled} = Hub.respond("ai-token", req.req_id, "text", "late")
    assert {:error, :request_cancelled} = Hub.action("ai-token", req.req_id)
    assert {:error, :request_cancelled} = Hub.edit("ai-token", req.req_id, "text", "late")
    assert Hub.request_trace(req.req_id).status == :cancelled
    send(Hub, {:expire_request, req.req_id})
    assert Hub.request_trace(req.req_id).status == :cancelled
    refute_receive {:sent, _}
  end

  test "queued requests are removed without being delivered" do
    incoming()
    state = :sys.get_state(Hub)
    [id] = Map.keys(state.delivery.pending)
    assert {:ok, %{delivery_status: "not_started"}} = Hub.cancel("ai-token", id)
    assert {:ok, []} = Hub.poll("ai-token")
    assert Hub.status().delivery_health.pending == 0
  end

  test "retained HTTP delivery drops cancelled siblings and can still be acknowledged" do
    incoming()
    incoming()
    {:ok, %{delivery_id: delivery, requests: [first, second]}} = Hub.poll_delivery("ai-token")
    {:ok, _} = Hub.cancel("ai-token", first.req_id)
    assert {:ok, %{delivery_id: ^delivery, requests: [^second]}} = Hub.poll_delivery("ai-token")
    {:ok, _} = Hub.cancel("ai-token", second.req_id)

    assert {:ok, %{requests: [], delivery_id: nil}} =
             Hub.poll_delivery("ai-token", delivery_ack: delivery)

    assert Hub.request_trace(first.req_id).status == :cancelled
  end

  test "cancelled socket delivery is not requeued on disconnect" do
    expire_client("assistant")
    pid = start_socket_process()
    {:ok, %{messages: []}} = Hub.connect_socket("ai-token", client_id: "socket", pid: pid)
    incoming()
    %{items: [req]} = :sys.get_state(Hub).delivery.clients["assistant"].socket_delivery
    {:ok, _} = Hub.cancel("ai-token", req.req_id)
    :ok = Hub.disconnect_socket("assistant", "socket", pid)
    assert {:ok, []} = Hub.poll("ai-token", client_id: "http")
  end

  test "cancelled socket batches keep acknowledgement ordering for following work" do
    expire_client("assistant")
    pid = start_socket_process()
    {:ok, _} = Hub.connect_socket("ai-token", client_id: "socket", pid: pid)
    :ok = incoming()
    %{ref: ref, items: [req]} = :sys.get_state(Hub).delivery.clients["assistant"].socket_delivery
    {:ok, _} = Hub.cancel("ai-token", req.req_id)

    assert %{ref: ^ref, items: []} =
             :sys.get_state(Hub).delivery.clients["assistant"].socket_delivery

    :ok = incoming()

    assert %{ref: ^ref, items: []} =
             :sys.get_state(Hub).delivery.clients["assistant"].socket_delivery

    Hub.complete_socket_delivery("assistant", "socket", pid, ref)
    state = :sys.get_state(Hub)
    assert %{items: [next]} = state.delivery.clients["assistant"].socket_delivery
    refute next.req_id == req.req_id
    assert Hub.request_trace(req.req_id).status == :cancelled
  end

  test "idle streams report confirmed delivery without deleting visible messages" do
    req = request()
    {:ok, _} = Hub.respond("ai-token", req.req_id, "text", "partial", final: false)
    assert_receive {:sent, %{data: "partial"}}

    assert {:ok, %{delivery_status: "partial", message_ids: [901]}} =
             Hub.cancel("ai-token", req.req_id)

    assert {:error, :request_cancelled} = Hub.respond("ai-token", req.req_id, "text", "finish")
    refute_receive {:sent, _}
  end

  test "cancellation stops an active HTTP attempt, replies to its caller and ignores late results" do
    parent = self()

    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
              sender: fn _, message ->
                send(parent, {:blocked, self(), message})

                receive do
                  :release -> {:ok, %{message_id: 901}}
                end
              end
            )
      }
    end)

    req = request()
    caller = respond_async(req.req_id)
    assert_receive {:blocked, worker, message}
    monitor = Process.monitor(worker)
    [{ref, _}] = Map.to_list(:sys.get_state(Hub).delivery.sends)
    assert {:ok, %{delivery_status: "unknown"}} = Hub.cancel("ai-token", req.req_id)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert_receive {:result, {:error, :request_cancelled}}
    wait_task(caller)
    send(Hub, {:send_complete, ref, {:ok, %{message | message_id: 901}}})
    send(Hub, {:send_timeout, ref})
    assert Hub.request_trace(req.req_id).status == :cancelled
    assert :sys.get_state(Hub).delivery.sends == %{}
    assert {:error, :request_cancelled} = Hub.edit("ai-token", req.req_id, "text", "late")
  end

  test "a response waiting for the bot coordinator is stopped before delivery" do
    parent = self()

    blocker =
      start_supervised!(
        {Task,
         fn ->
           Exiron.Hub.Telegram.SendCoordinator.run("bot-token", fn ->
             send(parent, :occupied)

             receive do
               :release -> :ok
             end
           end)
         end},
        id: :blocker
      )

    assert_receive :occupied
    req = request()
    :ok = Hub.subscribe_traces()
    caller = respond_async(req.req_id)
    await_stage(req.req_id, :send_started)
    assert {:ok, %{delivery_status: "not_started"}} = Hub.cancel("ai-token", req.req_id)
    assert_receive {:result, {:error, :request_cancelled}}
    send(blocker, :release)
    wait_task(blocker)
    wait_task(caller)
    refute_receive {:sent, _}
  end

  test "multipart cancellation preserves known IDs and stops all later parts" do
    parent = self()

    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
              sender: fn _, message ->
                count = Process.get(:parts, 0) + 1
                Process.put(:parts, count)
                send(parent, {:part, count, self(), message})

                if count == 1 do
                  {:ok, %{message_id: 901}}
                else
                  receive do
                    :release -> {:ok, %{message_id: 902}}
                  end
                end
              end
            )
      }
    end)

    req = request()
    caller = respond_async(req.req_id, String.duplicate("x", 8193))
    assert_receive {:part, 1, _, _}
    assert_receive {:part, 2, worker, _}
    monitor = Process.monitor(worker)

    assert {:ok, %{delivery_status: "unknown", message_ids: [901]}} =
             Hub.cancel("ai-token", req.req_id)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert_receive {:result, {:error, :request_cancelled}}
    wait_task(caller)
    refute_receive {:part, 3, _, _}
  end

  test "cancelling during a rate-limit cooldown prevents retry and reports partial delivery" do
    parent = self()

    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new([%{chat_id: 123, bot_token: "cooldown-cancel-test"}],
              sender: fn _, message ->
                send(parent, {:attempt, byte_size(message.data)})

                if byte_size(message.data) == 4096,
                  do: {:ok, %{message_id: 901}},
                  else:
                    {:error,
                     %ExGram.Error{code: 429, metadata: %{parameters: %{"retry_after" => 60}}}}
              end
            )
      }
    end)

    req = request()
    :ok = Hub.subscribe_traces()
    caller = respond_async(req.req_id, String.duplicate("x", 4097))
    await_stage(req.req_id, :telegram_rate_limited)

    assert {:ok, %{delivery_status: "partial", message_ids: [901]}} =
             Hub.cancel("ai-token", req.req_id)

    assert_receive {:result, {:error, :request_cancelled}}
    wait_task(caller)
    assert_receive {:attempt, 4096}
    assert_receive {:attempt, 1}
    refute_receive {:attempt, _}
  end

  test "expiry also terminates an in-flight response and cannot be resurrected" do
    parent = self()

    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
              sender: fn _, _ ->
                send(parent, {:blocked, self()})

                receive do
                  :release -> {:ok, %{message_id: 901}}
                end
              end
            )
      }
    end)

    req = request()
    caller = respond_async(req.req_id)
    assert_receive {:blocked, worker}
    monitor = Process.monitor(worker)
    send(Hub, {:expire_request, req.req_id})
    assert_receive {:result, {:error, :request_not_found}}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    wait_task(caller)
    assert Hub.request_trace(req.req_id).status == :expired
  end

  test "completed requests cannot be cancelled and completed replies remain editable" do
    req = request()
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "done")
    assert {:error, :request_not_found} = Hub.cancel("ai-token", req.req_id)
    assert :ok = Hub.edit("ai-token", req.req_id, "text", "corrected")
  end

  defp incoming,
    do:
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request", bot_token: "bot-token")
      )

  defp request do
    :ok = incoming()
    {:ok, [req]} = Hub.poll("ai-token")
    req
  end

  defp respond_async(id, text \\ "reply") do
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         send(parent, {:result, Hub.respond("ai-token", id, "text", text, parse_mode: "plain")})
       end},
      id: make_ref()
    )
  end

  defp wait_task(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}
    assert reason in [:normal, :noproc]
  end

  defp await_stage(id, kind) do
    assert_receive :request_traces_changed, 1000
    if not Enum.any?(Hub.request_trace(id).steps, &(&1.kind == kind)), do: await_stage(id, kind)
  end
end
