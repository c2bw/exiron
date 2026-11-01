defmodule Exiron.Hub.SupervisorTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub

  test "Hub workers are terminated when the Hub restarts" do
    old_hub = Process.whereis(Hub)
    old_telegram_supervisor = Process.whereis(Hub.TelegramSupervisor)
    old_send_supervisor = Process.whereis(Hub.SendSupervisor)
    old_lookup_supervisor = Process.whereis(Hub.LookupSupervisor)

    {:ok, telegram_worker} =
      DynamicSupervisor.start_child(
        Hub.TelegramSupervisor,
        temporary_task_spec()
      )

    {:ok, send_worker} =
      Task.Supervisor.start_child(Hub.SendSupervisor, fn ->
        receive do
          :stop -> :ok
        end
      end)

    hub_ref = Process.monitor(old_hub)
    telegram_supervisor_ref = Process.monitor(old_telegram_supervisor)
    send_supervisor_ref = Process.monitor(old_send_supervisor)
    lookup_supervisor_ref = Process.monitor(old_lookup_supervisor)
    telegram_worker_ref = Process.monitor(telegram_worker)
    send_worker_ref = Process.monitor(send_worker)

    Process.exit(old_hub, :kill)

    assert_receive {:DOWN, ^hub_ref, :process, ^old_hub, :killed}
    assert_receive {:DOWN, ^telegram_worker_ref, :process, ^telegram_worker, _reason}
    assert_receive {:DOWN, ^send_worker_ref, :process, ^send_worker, _reason}

    assert_receive {:DOWN, ^telegram_supervisor_ref, :process, ^old_telegram_supervisor, _reason}

    assert_receive {:DOWN, ^send_supervisor_ref, :process, ^old_send_supervisor, _reason}

    assert_receive {:DOWN, ^lookup_supervisor_ref, :process, ^old_lookup_supervisor, _reason}

    _ = :sys.get_state(Hub.Supervisor)

    new_hub = Process.whereis(Hub)
    new_telegram_supervisor = Process.whereis(Hub.TelegramSupervisor)
    new_send_supervisor = Process.whereis(Hub.SendSupervisor)
    new_lookup_supervisor = Process.whereis(Hub.LookupSupervisor)

    assert is_pid(new_hub)
    assert is_pid(new_telegram_supervisor)
    assert is_pid(new_send_supervisor)
    assert is_pid(new_lookup_supervisor)
    assert new_hub != old_hub
    assert new_telegram_supervisor != old_telegram_supervisor
    assert new_send_supervisor != old_send_supervisor
    assert new_lookup_supervisor != old_lookup_supervisor
  end

  defp temporary_task_spec do
    %{
      id: make_ref(),
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               :stop -> :ok
             end
           end
         ]},
      restart: :temporary
    }
  end
end
