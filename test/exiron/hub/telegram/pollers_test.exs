defmodule Exiron.Hub.Telegram.PollersTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.Telegram.Pollers

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    %{supervisor: supervisor}
  end

  test "reconciliation preserves a poller while updating its name", %{supervisor: supervisor} do
    parent = self()

    poller_options = fn _bot -> [get_updates: get_updates(parent)] end

    assert {:ok, pollers} =
             Pollers.reconcile(
               [%{token: "stable-token", name: "old-name"}],
               true,
               %{},
               supervisor: supervisor,
               poller_options: poller_options
             )

    %{pid: pid} = pollers["stable-token"]
    assert_receive {:poll_started, ^pid}

    assert {:ok, renamed} =
             Pollers.reconcile(
               [%{token: "stable-token", name: "new-name"}],
               true,
               pollers,
               supervisor: supervisor,
               poller_options: poller_options
             )

    assert %{pid: ^pid, bot_name: "new-name"} = renamed["stable-token"]
    send(pid, :release)
    assert %{bot_name: "new-name"} = :sys.get_state(pid)
  end

  test "reconciliation starts additions and stops removals", %{supervisor: supervisor} do
    parent = self()
    poller_options = fn _bot -> [get_updates: get_updates(parent)] end

    assert {:ok, initial} =
             Pollers.reconcile(
               [
                 %{token: "first-token", name: "first"},
                 %{token: "second-token", name: "second"}
               ],
               true,
               %{},
               supervisor: supervisor,
               poller_options: poller_options
             )

    %{pid: first_pid} = initial["first-token"]
    %{pid: second_pid} = initial["second-token"]
    assert_receive {:poll_started, ^first_pid}
    assert_receive {:poll_started, ^second_pid}

    monitor = Process.monitor(second_pid)

    assert {:ok, updated} =
             Pollers.reconcile(
               [%{token: "first-token", name: "first"}],
               true,
               initial,
               supervisor: supervisor,
               poller_options: poller_options
             )

    assert %{pid: ^first_pid} = updated["first-token"]
    refute Map.has_key?(updated, "second-token")
    assert_receive {:DOWN, ^monitor, :process, ^second_pid, _reason}
  end

  test "disabled reconciliation removes tracked pollers and starts none", %{
    supervisor: supervisor
  } do
    parent = self()
    poller_options = fn _bot -> [get_updates: get_updates(parent)] end

    assert {:ok, pollers} =
             Pollers.reconcile(
               [%{token: "disabled-token", name: "disabled"}],
               true,
               %{},
               supervisor: supervisor,
               poller_options: poller_options
             )

    %{pid: pid} = pollers["disabled-token"]
    assert_receive {:poll_started, ^pid}
    monitor = Process.monitor(pid)

    assert {:ok, %{}} =
             Pollers.reconcile(
               [%{token: "disabled-token", name: "disabled"}],
               false,
               pollers,
               supervisor: supervisor,
               poller_options: poller_options
             )

    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    assert DynamicSupervisor.count_children(supervisor).active == 0
  end

  test "a start failure is explicit and leaves prior pollers running", %{supervisor: supervisor} do
    parent = self()
    poller_options = fn _bot -> [get_updates: get_updates(parent)] end

    assert {:ok, pollers} =
             Pollers.reconcile(
               [%{token: "existing-token", name: "existing"}],
               true,
               %{},
               supervisor: supervisor,
               poller_options: poller_options
             )

    %{pid: existing_pid} = pollers["existing-token"]
    assert_receive {:poll_started, ^existing_pid}

    result =
      Pollers.reconcile(
        [
          %{token: "existing-token", name: "existing"},
          %{token: "new-token", name: "new"}
        ],
        true,
        pollers,
        supervisor: supervisor,
        start_child: fn _supervisor, bot, _spec ->
          if bot.token == "new-token",
            do: {:error, :unavailable},
            else: flunk("unexpected start")
        end
      )

    assert {:error,
            {:start_failed, %{bot_name: "new", token_fingerprint: "sha256:" <> fingerprint},
             :unavailable}} =
             result

    assert byte_size(fingerprint) == 12
    refute inspect(result) =~ "new-token"

    assert DynamicSupervisor.count_children(supervisor).active == 1
    assert %{pid: ^existing_pid} = pollers["existing-token"]
  end

  test "a stop failure is explicit and leaves the registered poller running", %{
    supervisor: supervisor
  } do
    parent = self()
    poller_options = fn _bot -> [get_updates: get_updates(parent)] end

    assert {:ok, pollers} =
             Pollers.reconcile(
               [%{token: "protected-token", name: "protected"}],
               true,
               %{},
               supervisor: supervisor,
               poller_options: poller_options
             )

    %{pid: pid} = pollers["protected-token"]
    assert_receive {:poll_started, ^pid}

    result =
      Pollers.reconcile(
        [],
        true,
        pollers,
        supervisor: supervisor,
        terminate_child: fn _supervisor, _pid -> {:error, :busy} end
      )

    assert {:error,
            {:stop_failed, %{bot_name: "protected", token_fingerprint: "sha256:" <> fingerprint},
             :busy}} =
             result

    assert byte_size(fingerprint) == 12
    refute inspect(result) =~ "protected-token"

    assert DynamicSupervisor.count_children(supervisor).active == 1
  end

  defp get_updates(parent) do
    fn _options ->
      send(parent, {:poll_started, self()})

      receive do
        :release -> {:ok, []}
      end
    end
  end
end
