defmodule Exiron.Hub.RequestTraceTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase

  alias Exiron.Hub
  alias Exiron.Hub.{Message, RequestTrace, State}

  test "correlates accepted requests, explicit acknowledgements and Telegram completion" do
    assert {:ok, %{requests: []}} = Hub.poll_delivery("ai-token", client_id: "worker")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai private body", "bot-token", message_id: 77)
      )

    assert {:ok, %{requests: [request], delivery_id: ack}} =
             Hub.poll_delivery("ai-token", client_id: "worker")

    assert {:ok, %{requests: []}} =
             Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: ack)

    trace = Hub.request_trace(request.req_id)
    assert trace.client_id == "worker"
    assert trace.message_id == 77
    assert trace.status == :awaiting_response
    assert trace.deliveries == 1
    assert :ok = Hub.respond("ai-token", request.req_id, "text", "private response")
    trace = Hub.request_trace(request.req_id)
    assert trace.status == :completed

    assert Enum.map(trace.steps, & &1.kind) == [
             :received,
             :route_selected,
             :queued,
             :client_delivered,
             :client_acknowledged,
             :response_received,
             :send_started,
             :telegram_attempt,
             :telegram_sent
           ]

    assert Enum.all?(trace.steps, &(&1.elapsed_ms >= 0))
    refute inspect(trace) =~ "private"
    refute inspect(trace) =~ "bot-token"
    refute inspect(trace) =~ "ai-token"
    refute Map.has_key?(trace, :started_at)
    refute Map.has_key?(Hub.status(), :traces)
    refute Map.has_key?(hd(Hub.request_traces()), :steps)
  end

  test "records expiry and preserves terminal outcomes after a late acknowledgement" do
    {:ok, _} = Hub.poll_delivery("ai-token", client_id: "worker")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

    {:ok, %{requests: [request], delivery_id: ack}} =
      Hub.poll_delivery("ai-token", client_id: "worker")

    send(Hub, {:expire_request, request.req_id})
    assert Hub.request_trace(request.req_id).status == :expired
    {:ok, _} = Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: ack)
    assert Hub.request_trace(request.req_id).status == :expired
  end

  test "records replay on client replacement" do
    socket = start_socket_process()
    assert {:ok, _} = Hub.connect_socket("ai-token", client_id: "socket", pid: socket)
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
    [trace] = Hub.request_traces()
    assert trace.deliveries == 1
    :ok = Hub.disconnect_socket("assistant", "socket", socket)
    assert {:ok, %{requests: [_]}} = Hub.poll_delivery("ai-token", client_id: "http-worker")
    trace = Hub.request_trace(trace.id)
    assert trace.deliveries == 2
    assert trace.client_id == "http-worker"
    assert Enum.any?(trace.steps, &(&1.kind == :requeued))
  end

  test "bounds trace and step retention independently of payload size" do
    message = Message.new(222, 123, "text", String.duplicate("x", 100_000), "secret")

    state =
      Enum.reduce(1..505, State.new(), fn id, state ->
        RequestTrace.start(state, to_string(id), message, "assistant", 1)
      end)

    assert length(RequestTrace.list(state)) == 500
    assert RequestTrace.fetch(state, "1") == nil

    state =
      Enum.reduce(1..100, state, fn _, state ->
        RequestTrace.record(state, "505", :client_delivered)
      end)

    trace = RequestTrace.fetch(state, "505")
    assert length(trace.steps) == 32
    assert trace.omitted_steps == 71
    assert Enum.take(Enum.map(trace.steps, & &1.kind), 3) == [:received, :route_selected, :queued]
    assert length(Enum.uniq_by(trace.steps, & &1.id)) == 32
    refute inspect(trace) =~ "secret"
  end

  test "snapshots expose current age and the actual pending expiry without leaking clocks" do
    timer = Process.send_after(self(), :timing_test_expiry, 60_000)
    on_exit(fn -> Process.cancel_timer(timer) end)

    state =
      RequestTrace.start(
        State.new(),
        "timed",
        Message.new(222, 123, "text", "private"),
        "assistant",
        1
      )

    state = put_in(state.delivery.pending["timed"], %{timer: timer})

    state =
      update_in(state.activity.traces["timed"], fn trace ->
        %{
          trace
          | started_at: trace.started_at - 120_000,
            phase_started_at: trace.phase_started_at - 90_000
        }
      end)

    trace = RequestTrace.fetch(state, "timed")
    assert trace.age_ms >= 120_000
    assert trace.elapsed_ms == 0
    assert trace.wait_phase == :client_queue
    assert trace.waiting_ms >= 90_000
    assert trace.expires_in_ms in 1..60_000
    assert trace.pending?
    refute Map.has_key?(trace, :phase_started_at)
    refute Map.has_key?(trace, :started_at)

    state = RequestTrace.record(state, "timed", :client_delivered, status: :delivered)
    assert RequestTrace.fetch(state, "timed").wait_phase == :client
    state = update_in(state.activity.traces["timed"].phase_started_at, &(&1 - 10_000))
    state = RequestTrace.record(state, "timed", :client_acknowledged, status: :awaiting_response)
    assert RequestTrace.fetch(state, "timed").waiting_ms >= 10_000
    state = RequestTrace.record(state, "timed", :response_received, status: :sending)
    trace = RequestTrace.fetch(state, "timed")
    assert trace.wait_phase == :telegram
    assert trace.waiting_ms < 10_000

    state = %{state | delivery: %{state.delivery | pending: %{}}}
    state = RequestTrace.record(state, "timed", :telegram_sent, status: :completed)
    trace = RequestTrace.fetch(state, "timed")
    refute trace.pending?
    assert is_nil(trace.expires_in_ms)
    assert is_nil(trace.wait_phase)
    assert is_nil(trace.waiting_ms)
  end
end
