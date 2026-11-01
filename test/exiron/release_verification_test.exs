defmodule Exiron.ReleaseVerificationTest do
  use Exiron.HubCase, async: false

  alias Exiron.{Hub, ReleaseMaintenance}

  @previous String.duplicate("0", 32)

  setup do
    :ok = Hub.resume_intake()
    on_exit(fn -> Hub.resume_intake() end)
    :ok
  end

  test "a ready old application boot cannot satisfy restart verification" do
    boot = ReleaseMaintenance.boot_id()
    assert Regex.match?(~r/\A[0-9a-f]{32}\z/, boot)
    assert %{ready: true} = Hub.readiness()
    assert :awaiting_restart = ReleaseMaintenance.restart_status(boot)
    assert :ready = ReleaseMaintenance.restart_status(@previous)
  end

  test "a new boot must also pass the Hub readiness check" do
    {:ok, _} = Hub.start_drain()
    assert :draining = ReleaseMaintenance.restart_status(@previous)
    :ok = Hub.resume_intake()
    assert :ready = ReleaseMaintenance.restart_status(@previous)
  end

  test "waits through the old boot, unavailable RPC and initialization before success" do
    observations =
      start_supervised!(
        {Agent, fn -> [:awaiting_restart, :hub_unavailable, :starting, :ready] end}
      )

    parent = self()

    probe = fn previous, remaining ->
      assert previous == @previous
      assert remaining > 0
      Agent.get_and_update(observations, fn [next | rest] -> {next, rest} end)
    end

    assert :ok =
             ReleaseMaintenance.await_restart(@previous,
               interval_ms: 1,
               probe: probe,
               on_progress: &send(parent, {:progress, &1})
             )

    assert_received {:progress, :awaiting_restart}
    assert_received {:progress, :hub_unavailable}
    assert_received {:progress, :starting}
    assert_received {:progress, :ready}
    assert Agent.get(observations, & &1) == []
  end

  test "timeout identifies the last observed failure and makes no changes to intake" do
    for status <- [:awaiting_restart, :hub_unavailable, :not_initialized] do
      assert {:error, {:startup_timeout, ^status}} =
               ReleaseMaintenance.await_restart(@previous,
                 timeout_ms: 5,
                 interval_ms: 1,
                 probe: fn _, _ -> status end,
                 on_progress: fn _ -> :ok end
               )
    end

    assert %{active: false} = Hub.drain_status()
  end

  test "definitive startup failures are reported without retry or rollback" do
    for status <- [:boot_failed, :disabled] do
      assert {:error, {:startup_failed, ^status}} =
               ReleaseMaintenance.await_restart(@previous,
                 probe: fn _, _ -> status end,
                 on_progress: fn _ -> :ok end
               )
    end
  end

  test "invalid identities and timeouts cannot start probes" do
    probe = fn _, _ -> flunk("invalid options must not probe a release") end

    for {identity, opts} <- [
          {"ready", []},
          {nil, []},
          {@previous, [timeout_ms: 0]},
          {@previous, [timeout_ms: 3_600_001]},
          {@previous, [interval_ms: 0]}
        ] do
      assert {:error, :invalid_options} =
               ReleaseMaintenance.await_restart(identity, Keyword.put(opts, :probe, probe))
    end
  end
end
