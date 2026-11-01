defmodule Exiron.Hub.ReloadManagerTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.State

  alias Exiron.Hub.ReloadManager

  @event [:exiron, :hub, :reload, :stop]

  test "reloads routes and emits a successful bounded outcome" do
    event = @event
    handler_id = attach_handler()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    state = %State{router: %Exiron.Hub.Router{}}

    assert {:ok, %{router: %Exiron.Hub.Router{}}} =
             ReloadManager.reload(state, :reload_routes,
               config_path: Path.expand("config/config.yml")
             )

    assert_receive {^event, %{duration: duration}, %{action: :reload_routes, outcome: :ok}}
    assert is_integer(duration) and duration >= 0
  end

  defp attach_handler do
    handler_id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    handler_id
  end
end
