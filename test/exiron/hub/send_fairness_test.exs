defmodule Exiron.Hub.SendFairnessTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{Message, SendBudget, Telegram}

  setup do
    router =
      load_router!("send-fairness", """
      aliases:
        telegram:
          home: 123
          work: 456
      routes:
        home:
          middleware: [family]
          push: true
        work:
          middleware: [work]
          push: true
      middlewares:
        family:
          routes:
            assistant:
              messages: ["/ai"]
        work:
          routes:
            quiet:
              messages: ["/quiet"]
      hooks:
        assistant: "ai-token"
        quiet: "quiet-token"
      """)

    parent = self()

    sender = fn token, message ->
      send(parent, {:attempt, token, message, self()})

      if message.data == "hold" do
        receive do
          :release -> :ok
        end
      end

      {:ok, %{message_id: message.edit_message_id || 901}}
    end

    :ok =
      Hub.configure(
        router,
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "busy-bot"},
            %{chat_id: 456, bot_token: "quiet-bot"}
          ],
          sender: sender
        )
      )

    :sys.replace_state(Hub, fn state ->
      %{
        state
        | settings: %{state.settings | max_in_flight_sends: 2, max_in_flight_sends_per_hook: 1}
      }
    end)

    {:ok, []} = Hub.poll("ai-token")
    {:ok, []} = Hub.poll("quiet-token")
    :ok
  end

  test "per-hook byte capacity rejects before Telegram while another hook can send" do
    edit_req = request()
    assert :ok = Hub.respond("ai-token", edit_req.req_id, "text", "receipt")
    req = request()
    bytes = SendBudget.payload_bytes("hold", [])
    byte_caps(1000, bytes)
    {caller, monitor} = call_async(fn -> Hub.push("ai-token", "text", "hold", 123) end)
    assert_receive {:attempt, "busy-bot", %{data: "hold"}, worker}
    assert hook("assistant").health.in_flight_send_bytes == bytes
    assert Hub.status().send_capacity.bytes == bytes

    for result <- [
          Hub.push("ai-token", "text", "x", 123),
          Hub.respond("ai-token", req.req_id, "text", "x"),
          Hub.action("ai-token", req.req_id, "typing"),
          Hub.edit("ai-token", edit_req.req_id, "text", "x")
        ] do
      assert result == {:error, :hook_send_queue_full}
    end

    assert Hub.status().send_capacity.rejections == 4
    assert hook("assistant").health.send_byte_capacity_rejections == 4
    assert {:ok, 1} = Hub.push("quiet-token", "text", "ok", 456)
    refute_received {:attempt, _, %{data: "x"}, _}
    send(worker, :release)
    assert_receive {:result, ^caller, {:ok, 1}}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert Hub.status().send_capacity.bytes == 0
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "ok")
    assert :ok = Hub.edit("ai-token", edit_req.req_id, "text", "ok")
  end

  test "global send bytes apply across hooks independently of operation counts" do
    bytes = SendBudget.payload_bytes("hold", [])
    byte_caps(bytes, 1000)
    {caller, monitor} = call_async(fn -> Hub.push("ai-token", "text", "hold", 123) end)
    assert_receive {:attempt, _, %{data: "hold"}, worker}
    assert {:error, :send_queue_full} = Hub.push("quiet-token", "text", "x", 456)
    assert Hub.status().send_capacity.rejections == 1
    assert hook("quiet").health.send_byte_capacity_rejections == 1
    send(worker, :release)
    assert_receive {:result, ^caller, {:ok, 1}}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert Hub.status().send_capacity.bytes == 0
    assert {:ok, 1} = Hub.push("quiet-token", "text", "ok", 456)
  end

  test "one busy hook cannot take every global slot and all send operations share its cap" do
    edit_req = request()
    assert :ok = Hub.respond("ai-token", edit_req.req_id, "text", "receipt")
    assert_receive {:attempt, "busy-bot", %{data: "receipt"}, _}
    req = request()
    {caller, monitor} = call_async(fn -> Hub.push("ai-token", "text", "hold", 123) end)
    assert_receive {:attempt, "busy-bot", %{data: "hold"}, worker}

    assert {:error, :hook_send_queue_full} = Hub.push("ai-token", "text", "rejected", 123)

    assert {:error, :hook_send_queue_full} =
             Hub.respond("ai-token", req.req_id, "text", "rejected")

    assert {:error, :hook_send_queue_full} = Hub.action("ai-token", req.req_id, "typing")

    assert {:error, :hook_send_queue_full} =
             Hub.edit("ai-token", edit_req.req_id, "text", "rejected")

    assert {:error, :invalid_token} = Hub.push("wrong", "text", "rejected", 123)

    assert {:ok, 1} = Hub.push("quiet-token", "text", "quiet succeeds", 456)
    assert_receive {:attempt, "quiet-bot", %{data: "quiet succeeds"}, _}
    refute_received {:attempt, _, %{data: "rejected"}, _}
    busy = hook("assistant")
    assert busy.health.in_flight_sends == 1
    assert busy.health.in_flight_send_limit == 1
    assert busy.health.send_capacity_rejections == 4
    assert busy.health.send_failures == 0
    assert hook("quiet").health.send_capacity_rejections == 0
    refute Exiron.Hub.PendingRequest.responding?(:sys.get_state(Hub).delivery.pending[req.req_id])
    refute :sys.get_state(Hub).delivery.replies[edit_req.req_id].busy?

    send(worker, :release)
    assert_receive {:result, ^caller, {:ok, 1}}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert hook("assistant").health.in_flight_sends == 0
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "accepted after release")
    assert :ok = Hub.edit("ai-token", edit_req.req_id, "text", "edit after release")
  end

  test "the global cap still applies independently" do
    :sys.replace_state(Hub, fn s -> %{s | settings: %{s.settings | max_in_flight_sends: 1}} end)
    {caller, monitor} = call_async(fn -> Hub.push("ai-token", "text", "hold", 123) end)
    assert_receive {:attempt, _, %{data: "hold"}, worker}
    assert {:error, :send_queue_full} = Hub.push("quiet-token", "text", "rejected", 456)
    assert hook("quiet").health.send_capacity_rejections == 1
    send(worker, :release)
    assert_receive {:result, ^caller, {:ok, 1}}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert {:ok, 1} = Hub.push("quiet-token", "text", "accepted", 456)
  end

  test "rejected stream updates preserve the receipt and can be retried explicitly" do
    req = request()

    assert {:ok, %{message_id: 901}} =
             Hub.respond("ai-token", req.req_id, "text", "partial", final: false)

    assert_receive {:attempt, _, %{data: "partial"}, _}
    {caller, monitor} = call_async(fn -> Hub.push("ai-token", "text", "hold", 123) end)
    assert_receive {:attempt, _, %{data: "hold"}, worker}

    assert {:error, :hook_send_queue_full} =
             Hub.respond("ai-token", req.req_id, "text", "partial done")

    send(worker, :release)
    assert_receive {:result, ^caller, {:ok, 1}}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "partial done")
    assert_receive {:attempt, _, %{data: "partial done", edit_message_id: 901}, _}
  end

  test "cancelled, timed-out and crashed workers release the hook slot" do
    for outcome <- [:cancel, :timeout, :crash] do
      req = request()

      {caller, monitor} =
        call_async(fn -> Hub.respond("ai-token", req.req_id, "text", "hold") end)

      assert_receive {:attempt, _, %{data: "hold"}, worker}
      assert Hub.status().send_capacity.bytes > 0
      worker_monitor = Process.monitor(worker)

      case outcome do
        :cancel ->
          assert {:ok, _} = Hub.cancel("ai-token", req.req_id)

        :timeout ->
          [{ref, _}] = Map.to_list(:sys.get_state(Hub).delivery.sends)
          send(Hub, {:send_timeout, ref})

        :crash ->
          Process.exit(worker, :kill)
      end

      assert_receive {:result, ^caller, {:error, _}}
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}
      assert hook("assistant").health.in_flight_sends == 0
      assert Hub.status().send_capacity.bytes == 0
      assert {:ok, 1} = Hub.push("ai-token", "text", "slot released", 123)
      assert_receive {:attempt, _, %{data: "slot released"}, _}
    end
  end

  test "operations waiting for the same bot still count against their hook" do
    bytes = SendBudget.payload_bytes("hold", []) + SendBudget.payload_bytes("waiting", [])
    byte_caps(1000, bytes)

    {first, first_monitor} = call_async(fn -> Hub.push("ai-token", "text", "hold", 123) end)
    assert_receive {:attempt, "busy-bot", %{data: "hold"}, worker}
    {second, second_monitor} = call_async(fn -> Hub.push("ai-token", "text", "waiting", 123) end)
    assert_eventually(fn -> assert hook("assistant").health.in_flight_sends == 2 end)
    assert hook("assistant").health.in_flight_send_bytes == bytes
    refute_received {:attempt, _, %{data: "waiting"}, _}
    assert {:error, :hook_send_queue_full} = Hub.push("ai-token", "text", "reject", 123)
    assert {:ok, 1} = Hub.push("quiet-token", "text", "ok", 456)
    assert_receive {:attempt, "quiet-bot", %{data: "ok"}, _}
    send(worker, :release)
    assert_receive {:result, ^first, {:ok, 1}}
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}
    assert_receive {:attempt, "busy-bot", %{data: "waiting"}, _}
    assert_receive {:result, ^second, {:ok, 1}}
    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}
    assert hook("assistant").health.in_flight_sends == 0
  end

  defp byte_caps(global, hook) do
    :sys.replace_state(Hub, fn state ->
      %{
        state
        | settings: %{
            state.settings
            | max_in_flight_sends: 10,
              max_in_flight_sends_per_hook: 10,
              max_in_flight_send_bytes: global,
              max_in_flight_send_bytes_per_hook: hook
          }
      }
    end)
  end

  defp request do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request",
          bot_token: "busy-bot",
          message_id: System.unique_integer([:positive])
        )
      )

    {:ok, [req]} = Hub.poll("ai-token")
    req
  end

  defp hook(name), do: Enum.find(Hub.status().hooks, &(&1.name == name))

  defp call_async(fun) do
    parent = self()

    pid =
      start_supervised!({Task, fn -> send(parent, {:result, self(), fun.()}) end}, id: make_ref())

    {pid, Process.monitor(pid)}
  end
end
