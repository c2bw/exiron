defmodule Exiron.ReleaseMaintenanceTest do
  use Exiron.HubCase, async: false

  alias Exiron.{Hub, ReleaseMaintenance}
  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok =
      Hub.configure(
        load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:ok, %{message_id: 901}} end
        )
      )

    :ok = Hub.resume_intake()
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    on_exit(fn -> Hub.resume_intake() end)
    :ok
  end

  test "an empty drain succeeds and prints all four counts" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = ReleaseMaintenance.drain()
      end)

    assert output =~ "Drain drained: pending_requests=0 queued_messages=0"
    assert output =~ "active_sends=0 unacknowledged_batches=0"
    assert %{active: true, drained: true} = Hub.drain_status()
  end

  test "waits for final replies and batch acknowledgement while streaming still works" do
    :ok = incoming(1)
    :ok = incoming(2)

    {:ok, %{delivery_id: batch, requests: [one, two]}} =
      Hub.poll_delivery("ai-token", client_id: "worker")

    parent = self()

    progress = fn snapshot ->
      send(parent, {:progress, snapshot})

      if snapshot.pending_requests == 2 do
        assert {:ok, %{final: false}} =
                 Hub.respond("ai-token", one.req_id, "text", "partial", final: false)

        assert :ok = Hub.respond("ai-token", one.req_id, "text", "done")
        assert :ok = Hub.respond("ai-token", two.req_id, "text", "one-shot")
      end

      if snapshot.pending_requests == 0 and snapshot.unacknowledged_batches == 1 do
        assert {:ok, %{requests: []}} =
                 Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: batch)
      end
    end

    assert :ok = ReleaseMaintenance.drain(interval_ms: 1, on_progress: progress)
    assert_received {:progress, %{pending_requests: 2, drained: false}}
    assert_received {:progress, %{pending_requests: 0, unacknowledged_batches: 1, drained: false}}
    assert_received {:progress, %{drained: true}}
  end

  test "local timeout leaves outstanding work and the running Hub paused" do
    :ok = incoming(1)

    assert {:error, :drain_timed_out} =
             ReleaseMaintenance.drain(timeout_ms: 5, interval_ms: 1, on_progress: fn _ -> :ok end)

    assert %{active: true, pending_requests: 1, drained: false} = Hub.drain_status()
    assert {:retry, :draining} = incoming(2)
  end

  test "an existing timed-out drain is not reset or resumed" do
    :ok = incoming(1)
    {:ok, original} = Hub.start_drain(timeout_ms: 60_000)
    generation = :sys.get_state(Hub).drain.generation
    send(Hub, {:drain_timeout, generation})

    assert {:error, :drain_timed_out} =
             ReleaseMaintenance.drain(on_progress: fn _ -> :ok end)

    assert %{active: true, phase: "timed_out", started_at: started_at, timeout_ms: 60_000} =
             Hub.drain_status()

    assert started_at == original.started_at
  end

  test "resuming intake while waiting aborts the helper" do
    :ok = incoming(1)

    progress = fn snapshot ->
      if snapshot.active, do: Hub.resume_intake()
    end

    assert {:error, :drain_cancelled} =
             ReleaseMaintenance.drain(interval_ms: 1, on_progress: progress)
  end

  test "replacing the drain while waiting aborts the helper" do
    :ok = incoming(1)

    progress = fn snapshot ->
      if snapshot.active do
        :ok = Hub.resume_intake()
        {:ok, _} = Hub.start_drain()
      end
    end

    assert {:error, :drain_replaced} =
             ReleaseMaintenance.drain(interval_ms: 1, on_progress: progress)
  end

  test "invalid options do not pause intake" do
    for opts <- [[timeout_ms: 0], [timeout_ms: 3_600_001], [interval_ms: 0], [on_progress: nil]] do
      assert {:error, :invalid_options} = ReleaseMaintenance.drain(opts)
      assert %{active: false} = Hub.drain_status()
    end
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
