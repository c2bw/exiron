defmodule ExironWeb.MonitorRequestTimingTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:ok, %{message_id: 901}} end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "arrival, live age and phase waits update without a new lifecycle event", %{conn: conn} do
    id = incoming(1)
    age(id, 65_000)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    row = "#request-trace-#{id}"
    assert has_element?(view, row <> "-received[datetime]")
    assert has_element?(view, row <> "-timing-age", "Age 1m")

    assert has_element?(
             view,
             row <> "-timing-wait[data-phase=client_queue]",
             "Waiting for client pickup"
           )

    assert has_element?(view, row <> "[data-attention=long_wait]")
    {:ok, [_]} = Hub.poll("ai-token")

    assert_eventually(fn ->
      assert has_element?(view, row <> "-timing-wait[data-phase=client]")
    end)

    age(id, 125_000)
    send(view.pid, :refresh_request_activity)
    assert_eventually(fn -> assert has_element?(view, row <> "-timing-age", "Age 2m") end)
    view |> element(row <> "-inspect") |> render_click()
    assert has_element?(view, "#exiron-detail-received[datetime]")
    assert has_element?(view, "#exiron-detail-timing-wait[data-phase=client]")
  end

  test "time ranges use receipt age and freeze with the paused snapshot", %{conn: conn} do
    old = incoming(1)
    age(old, 3_700_000)
    recent = incoming(2)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    view |> form("#exiron-activity-filters", activity: %{range: "5m"}) |> render_change()
    refute has_element?(view, "#request-trace-#{old}")
    assert has_element?(view, "#request-trace-#{recent}")
    view |> form("#exiron-activity-filters", activity: %{range: "1h"}) |> render_change()
    refute has_element?(view, "#request-trace-#{old}")
    view |> element("#exiron-toggle-live") |> render_click()
    age(recent, 3_700_000)
    send(view.pid, :refresh_request_activity)
    assert has_element?(view, "#request-trace-#{recent}")
    view |> form("#exiron-activity-filters", activity: %{range: "5m"}) |> render_change()
    assert has_element?(view, "#request-trace-#{recent}")
    view |> element("#exiron-toggle-live") |> render_click()
    refute has_element?(view, "#request-trace-#{recent}")
    view |> form("#exiron-activity-filters", activity: %{range: ""}) |> render_change()
    assert has_element?(view, "#request-trace-#{old}")
    assert has_element?(view, "#request-trace-#{recent}")
  end

  test "expiry countdown freezes while paused and disappears on completion", %{conn: conn} do
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token")

    :sys.replace_state(Hub, fn state ->
      pending = state.delivery.pending[id]
      Process.cancel_timer(pending.timer)
      timer = Process.send_after(Hub, {:expire_request, id}, 25_000)
      put_in(state.delivery.pending[id], %{pending | timer: timer})
    end)

    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    row = "#request-trace-#{id}"
    assert has_element?(view, row <> "[data-attention=expiring]")
    assert has_element?(view, row <> "-timing-expiry", "Expires in")
    view |> element("#exiron-toggle-live") |> render_click()

    frozen =
      view
      |> element(row <> "-timing-expiry")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    :sys.replace_state(Hub, fn state ->
      pending = state.delivery.pending[id]
      Process.cancel_timer(pending.timer)
      timer = Process.send_after(Hub, {:expire_request, id}, 5_000)
      put_in(state.delivery.pending[id], %{pending | timer: timer})
    end)

    send(view.pid, :refresh_request_activity)
    assert has_element?(view, row <> "-timing-expiry", frozen)
    view |> element("#exiron-toggle-live") |> render_click()
    assert has_element?(view, row <> "-timing-expiry", "Expires in")
    assert :ok = Hub.respond("ai-token", id, "text", "done")

    assert_eventually(fn ->
      assert has_element?(view, row <> "[data-outcome=completed]")
      refute has_element?(view, row <> "-timing-expiry")
      refute has_element?(view, row <> "-timing-wait")
      refute has_element?(view, row <> "[data-attention]")
    end)
  end

  test "long Telegram sends have a distinct wait indicator", %{conn: conn} do
    parent = self()

    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ ->
            send(parent, {:sending, self()})

            receive do
              :release -> {:ok, %{message_id: 901}}
            end
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token")

    task =
      start_supervised!(
        {Task, fn -> send(parent, {:result, Hub.respond("ai-token", id, "text", "reply")}) end}
      )

    monitor = Process.monitor(task)
    assert_receive {:sending, sender}
    age(id, 20_000)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    row = "#request-trace-#{id}"
    assert has_element?(view, row <> "[data-attention=long_wait]")

    assert has_element?(
             view,
             row <> "-timing-wait[data-phase=telegram]",
             "Waiting for Telegram delivery"
           )

    send(sender, :release)
    assert_receive {:result, :ok}
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
  end

  defp incoming(n) do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request #{n}",
          bot_token: "bot-token",
          message_id: n
        )
      )

    hd(Hub.request_traces()).id
  end

  defp age(id, milliseconds) do
    :sys.replace_state(Hub, fn state ->
      now = System.monotonic_time(:millisecond)

      update_in(
        state.activity.traces[id],
        &%{&1 | started_at: now - milliseconds, phase_started_at: now - milliseconds}
      )
    end)
  end
end
