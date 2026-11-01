defmodule ExironWeb.MonitorDrainTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub

  setup do
    :ok = Hub.configure(Exiron.HubCase.load_router!(), Exiron.Hub.Telegram.new([]))
    on_exit(fn -> Hub.resume_intake() end)
    :ok
  end

  test "authenticated operator drains and resumes from the monitor", %{conn: conn} do
    {:ok, view, _} = live(log_in(conn), ~p"/monitor")
    assert has_element?(view, "#exiron-drain-phase[data-phase=running]")
    view |> form("#exiron-drain-form", drain: %{timeout_seconds: "60"}) |> render_submit()
    assert has_element?(view, "#exiron-drain-phase[data-phase=drained]")
    assert has_element?(view, "#exiron-drain-complete")
    assert has_element?(view, "#exiron-drain-unacknowledged_batches", "0")
    assert %{ready: false, reason: :draining} = Hub.readiness()
    view |> element("#exiron-drain-resume") |> render_click()
    assert has_element?(view, "#exiron-drain-phase[data-phase=running]")
    assert %{ready: true} = Hub.readiness()
  end

  test "paused views and invalid timeouts cannot change admission", %{conn: conn} do
    {:ok, view, _} = live(log_in(conn), ~p"/monitor")
    view |> form("#exiron-drain-form", drain: %{timeout_seconds: "0"}) |> render_submit()
    assert %{active: false} = Hub.drain_status()
    view |> element("#exiron-toggle-live") |> render_click()
    assert has_element?(view, "#exiron-drain-start[disabled]")
    render_hook(view, "start_drain", %{drain: %{timeout_seconds: "60"}})
    assert %{active: false} = Hub.drain_status()
  end

  test "progress stays current when activity is paused", %{conn: conn} do
    {:ok, view, _} = live(log_in(conn), ~p"/monitor")
    view |> element("#exiron-toggle-live") |> render_click()
    {:ok, _} = Hub.start_drain()
    send(view.pid, :refresh_request_activity)
    assert has_element?(view, "#exiron-drain-phase[data-phase=drained]")
    assert has_element?(view, "#exiron-drain-resume[disabled]")
  end
end
