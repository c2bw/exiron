defmodule Exiron.Hub.Telegram.PollersSeamTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.Telegram.Pollers

  setup do
    %{supervisor: start_supervised!({DynamicSupervisor, strategy: :one_for_one})}
  end

  test "disabled polling starts no children", %{supervisor: supervisor} do
    assert :ok =
             Pollers.start([%{token: "secret-token", name: "helper"}], false,
               supervisor: supervisor
             )

    assert DynamicSupervisor.count_children(supervisor).active == 0
  end

  test "stop terminates all pollers under the supplied supervisor", %{supervisor: supervisor} do
    parent = self()

    assert :ok =
             Pollers.start(
               [%{token: "secret-token", name: "helper"}],
               true,
               supervisor: supervisor,
               poller_options: [
                 empty_poll_delay: 60_000,
                 get_updates: fn _options ->
                   send(parent, {:poll_started, self()})
                   {:ok, []}
                 end
               ]
             )

    assert_receive {:poll_started, pid}
    ref = Process.monitor(pid)
    send(pid, :release)
    assert :ok = Pollers.stop(supervisor: supervisor)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    assert DynamicSupervisor.count_children(supervisor).active == 0
  end

  test "updates a registered poller's name through the map seam", %{supervisor: supervisor} do
    parent = self()

    assert {:ok, pollers} =
             Pollers.reconcile(
               [%{token: "secret-token", name: "old-name"}],
               true,
               %{},
               supervisor: supervisor,
               poller_options: [
                 empty_poll_delay: 60_000,
                 get_updates: fn _options ->
                   send(parent, {:poll_started, self()})

                   {:ok, []}
                 end
               ]
             )

    assert_receive {:poll_started, pid}
    assert :ok = Pollers.put_bot_name(pollers, "secret-token", "new-name")
    assert %{bot_name: "new-name"} = :sys.get_state(pid)
    assert :ok = Pollers.stop(supervisor: supervisor)
  end
end
