defmodule Exiron.TelemetryTest do
  use ExUnit.Case, async: true

  alias Exiron.Telemetry

  test "emits queue measurements with bounded metadata" do
    event = [:exiron, :hub, :queue]
    handler_id = attach_handler(event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Telemetry.queue(2, 128, 1, "notifications")

    assert_receive {^event, %{count: 2, bytes: 128, dropped: 1}, %{hook: "notifications"}}
  end

  test "emits timed operation outcomes" do
    event = [:exiron, :hub, :reload, :stop]
    handler_id = attach_handler(event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Telemetry.reload(42, :reload_configuration, :ok)

    assert_receive {^event, %{duration: 42}, %{action: :reload_configuration, outcome: :ok}}
  end

  test "emits every bounded domain event with its documented shape" do
    cases = [
      {[:exiron, :hub, :pending], fn -> Telemetry.pending(3) end, %{count: 3}, %{}},
      {[:exiron, :hub, :send, :stop], fn -> Telemetry.send(5, :push, :ok) end, %{duration: 5},
       %{kind: :push, outcome: :ok}},
      {[:exiron, :hub, :status, :snapshot, :stop],
       fn -> Telemetry.status_snapshot(7, 128, :global) end, %{duration: 7, bytes: 128},
       %{scope: :global}},
      {[:exiron, :hub, :lookup, :stop], fn -> Telemetry.lookup(9, :error) end, %{duration: 9},
       %{outcome: :error}},
      {[:exiron, :telegram, :poll, :stop], fn -> Telemetry.poll(11, :ok) end, %{duration: 11},
       %{outcome: :ok}},
      {[:exiron, :hub, :delivery, :redelivery], fn -> Telemetry.redelivery(:websocket) end,
       %{count: 1}, %{transport: :websocket}},
      {[:exiron, :hub, :listener, :drop], fn -> Telemetry.listener_drop("assistant", :full) end,
       %{count: 1}, %{hook: "assistant", reason: :full}}
    ]

    for {event, emit, measurements, metadata} <- cases do
      handler_id = attach_handler(event)
      assert :ok = emit.()
      assert_receive {^event, ^measurements, ^metadata}
      :ok = :telemetry.detach(handler_id)
    end
  end

  test "reload manager emits the reload outcome" do
    event = [:exiron, :hub, :reload, :stop]
    handler_id = attach_handler(event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    config_path =
      Path.join(
        System.tmp_dir!(),
        "exiron-invalid-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(config_path, "[")
    on_exit(fn -> File.rm(config_path) end)

    state = %{router: :unchanged}

    assert {:error, _reason} =
             Exiron.Hub.ReloadManager.reload(state, :reload_routes,
               enabled: true,
               config_path: config_path
             )

    assert_receive {^event, %{duration: duration}, %{action: :reload_routes, outcome: :error}}
    assert is_integer(duration) and duration >= 0
  end

  defp attach_handler(event) do
    handler_id = {__MODULE__, self(), event}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn name, measurements, metadata, _config ->
          send(test_pid, {name, measurements, metadata})
        end,
        nil
      )

    handler_id
  end
end
