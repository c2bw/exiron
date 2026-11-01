defmodule Exiron.Hub.DeliveryDiagnosticsTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{DeliveryDiagnostics, Message, Telegram}

  setup do
    router = load_push_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "other", Exiron.Hub.HookToken.hash("other-token"))
    }

    parent = self()

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "helper"}],
          sender: fn _, message ->
            send(parent, {:sent, message})

            if byte_size(message.data) == 4096 and not Process.get(:confirmed_part, false),
              do:
                (
                  Process.put(:confirmed_part, true)
                  {:ok, %{message_id: 901}}
                ),
              else: {:error, %ExGram.Error{code: 400, message: "secret-body bot-token"}}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "partial failures retain confirmed, rejected and unattempted parts without raw contents" do
    req = request()
    text = String.duplicate("x", 4096) <> String.duplicate("y", 4096) <> "secret-body"
    # The test sender confirms the first part, then rejects the second.
    assert {:error, :telegram_delivery_timeout} =
             Hub.respond("ai-token", req.req_id, "text", text, parse_mode: "plain")

    assert {:ok, d} = Hub.delivery_diagnostics("ai-token", req.req_id)
    assert d.delivery_status == "partial"
    assert d.confirmed_parts == 1
    assert d.rejected_parts == 1
    assert d.unattempted_parts == 1
    assert d.last_error.code == 400
    assert d.retry_action == "inspect_chat"
    refute d.retry_safe
    refute d.retry_available
    assert Enum.map(d.parts, & &1.status) == ["confirmed", "rejected", "queued"]
    assert {:ok, ^d} = Hub.delivery_diagnostics("ai-token", d.id)
    assert {:error, :request_not_assigned} = Hub.delivery_diagnostics("other-token", d.id)
    refute Jason.encode!(d) =~ "secret-body"
    refute Jason.encode!(d) =~ "bot-token"
    assert Hub.request_trace(req.req_id).delivery == d
  end

  test "unknown transport failures never advertise safe retries even when the request remains open" do
    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
              sender: fn _, _ ->
                {:error, %ExGram.Error{code: :transport_error, message: "private"}}
              end
            )
      }
    end)

    req = request()
    assert {:error, _} = Hub.respond("ai-token", req.req_id, "text", "text")
    {:ok, d} = Hub.delivery_diagnostics("ai-token", req.req_id)
    assert d.delivery_status == "unknown"
    assert d.unknown_parts == 1
    assert d.retry_available
    refute d.retry_safe
    assert d.retry_action == "inspect_chat"
  end

  test "429 rejection exposes a safe explicit retry with the Telegram delay" do
    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new([%{chat_id: 123, bot_token: "rate-diagnostic"}],
              sender: fn _, _ ->
                {:error, %ExGram.Error{code: 429, metadata: %{parameters: %{"retry_after" => 1}}}}
              end
            )
      }
    end)

    req = request()

    assert {:error, %ExGram.Error{code: 429}} =
             Hub.respond("ai-token", req.req_id, "text", "text")

    {:ok, d} = Hub.delivery_diagnostics("ai-token", req.req_id)
    assert d.parts |> hd() |> Map.fetch!(:attempts) == 3
    assert d.attempts == 3
    assert d.rejected_parts == 1
    assert d.in_flight_parts == 0
    assert d.last_error.retry_after_ms == 1000
    assert d.retry_safe
    assert d.retry_action == "retry_request"
  end

  test "live diagnostics and timeout distinguish queued work from an in-flight attempt" do
    parent = self()

    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
              sender: fn _, _ ->
                send(parent, {:blocked, self()})

                receive do
                  :finish -> {:ok, %{message_id: 901}}
                end
              end
            )
      }
    end)

    req = request()

    caller =
      start_supervised!(
        {Task,
         fn -> send(parent, {:result, Hub.respond("ai-token", req.req_id, "text", "text")}) end}
      )

    caller_ref = Process.monitor(caller)
    assert_receive {:blocked, worker}
    ref = Process.monitor(worker)
    {:ok, live} = Hub.delivery_diagnostics("ai-token", req.req_id)
    assert live.outcome == "sending"
    assert live.in_flight_parts == 1
    assert live.retry_action == "wait"
    [{send_ref, _}] = Map.to_list(:sys.get_state(Hub).delivery.sends)
    send(Hub, {:send_timeout, send_ref})
    assert_receive {:result, {:error, :telegram_delivery_timeout}}
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    {:ok, d} = Hub.delivery_diagnostics("ai-token", live.id)
    assert d.outcome == "timed_out"
    assert d.unknown_parts == 1
    assert d.in_flight_parts == 0
    refute d.retry_safe
  end

  test "an untrackable streaming receipt reports partial failure rather than success" do
    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: fn _, _ -> :ok end)
      }
    end)

    req = request()

    assert {:error, :telegram_delivery_timeout} =
             Hub.respond("ai-token", req.req_id, "text", "partial", final: false)

    {:ok, d} = Hub.delivery_diagnostics("ai-token", req.req_id)
    assert d.outcome == "failed"
    assert Hub.request_trace(req.req_id).status == :failed
    assert d.last_error.category == "delivery_timeout"
    assert d.delivery_status == "partial"
    assert d.retry_action == "inspect_chat"
    refute d.retry_safe
  end

  test "a deadline before any attempt does not imply uncertain delivery" do
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

    blocker_ref = Process.monitor(blocker)
    assert_receive :occupied
    req = request()
    :ok = Hub.subscribe_traces()

    caller =
      start_supervised!(
        {Task,
         fn ->
           send(parent, {:queued_result, Hub.respond("ai-token", req.req_id, "text", "queued")})
         end},
        id: :caller
      )

    caller_ref = Process.monitor(caller)
    assert_receive :request_traces_changed
    [{ref, _}] = Map.to_list(:sys.get_state(Hub).delivery.sends)
    send(Hub, {:send_timeout, ref})
    assert_receive {:queued_result, {:error, :telegram_delivery_timeout}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    {:ok, d} = Hub.delivery_diagnostics("ai-token", req.req_id)
    assert d.delivery_status == "not_started"
    assert d.attempts == 0
    assert Hub.request_trace(req.req_id).status == :failed
    send(blocker, :release)
    assert_receive {:DOWN, ^blocker_ref, :process, ^blocker, :normal}
    refute_receive {:sent, _}
  end

  test "push errors are inspectable by diagnostic ID from failure history" do
    assert {:error, %ExGram.Error{code: 400}} = Hub.push("ai-token", "text", "secret-body", 123)
    [failure] = Hub.status().send_failures
    assert failure.delivery.request_id == nil
    assert failure.delivery.operation == "push"
    assert failure.delivery.retry_safe
    assert {:ok, d} = Hub.delivery_diagnostics("ai-token", failure.delivery.id)
    assert d.last_error.code == 400
  end

  test "part detail truncation keeps exact totals and conservative guidance" do
    command = %Exiron.Hub.SendCommand{kind: :push, hook: "assistant"}
    d = DeliveryDiagnostics.new(command)

    d =
      Enum.reduce(1..150, d, fn chat, d ->
        meta = %{chat_id: chat, index: 1, operation: "send", bot_name: "helper", message_id: nil}

        d
        |> DeliveryDiagnostics.planned([meta])
        |> DeliveryDiagnostics.begin_attempt(meta)
        |> DeliveryDiagnostics.finish_attempt(:ok, [chat], nil)
      end)

    d =
      d
      |> DeliveryDiagnostics.finish("failed", :telegram_delivery_timeout, true)
      |> DeliveryDiagnostics.snapshot()

    assert length(d.parts) == 128
    assert d.omitted_parts == 22
    assert d.confirmed_parts == 150
    assert d.unattempted_parts == 0
    assert d.retry_action == "inspect_chat"
  end

  defp request do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request", bot_token: "bot-token")
      )

    {:ok, [req]} = Hub.poll("ai-token")
    req
  end
end
