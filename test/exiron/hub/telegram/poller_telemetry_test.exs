defmodule Exiron.Hub.Telegram.PollerTelemetryTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.Telegram.Poller
  alias Exiron.Hub.Telegram.PollerState

  @event [:exiron, :telegram, :poll, :stop]

  test "emits bounded success telemetry for a getUpdates attempt" do
    parent = self()
    event = @event
    handler_id = attach_handler(parent)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    pid =
      start_supervised!(
        {Poller,
         token: "secret-token",
         get_updates: fn options ->
           send(parent, {:poll_options, options})
           {:ok, []}
         end,
         empty_poll_delay: 60_000}
      )

    assert_receive {:poll_options, options}
    assert Keyword.fetch!(options, :timeout) == 25
    assert_receive {:telemetry, ^event, %{duration: duration}, metadata}
    assert metadata == %{outcome: :ok}
    assert is_integer(duration) and duration >= 0

    stop_and_assert_down(pid)
  end

  test "emits error telemetry when getUpdates returns an error" do
    parent = self()
    event = @event
    handler_id = attach_handler(parent)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    pid =
      start_supervised!(
        {Poller,
         token: "secret-token",
         get_updates: fn options ->
           send(parent, {:poll_options, options})
           {:error, :timeout}
         end}
      )

    assert_receive {:poll_options, _options}
    assert_receive {:telemetry, ^event, %{duration: duration}, metadata}
    assert metadata == %{outcome: :error}
    assert is_integer(duration) and duration >= 0

    stop_and_assert_down(pid)
  end

  test "emits exception telemetry before propagating a getUpdates crash" do
    event = @event
    handler_id = attach_handler(self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    state = %PollerState{
      token: "secret-token",
      get_updates: fn _options -> raise "poll failed" end,
      offset: nil,
      empty_poll_delay: 100
    }

    assert_raise RuntimeError, "poll failed", fn -> Poller.handle_continue(:poll, state) end
    assert_receive {:telemetry, ^event, %{duration: duration}, metadata}
    assert metadata == %{outcome: :exception}
    assert is_integer(duration) and duration >= 0
  end

  defp attach_handler(test_pid) do
    handler_id = {__MODULE__, test_pid, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    handler_id
  end

  defp stop_and_assert_down(pid) do
    ref = Process.monitor(pid)
    assert :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
