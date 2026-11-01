defmodule ExironWeb.MonitorClientRuntimeTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub

  setup do
    :ok = Hub.configure(Exiron.HubCase.load_router!(), Exiron.Hub.Telegram.new([]))
    {:ok, delivery} = Hub.poll_delivery("ai-token", client_id: "worker")

    payload =
      File.read!("clients/contract/client_runtime_report.json")
      |> Jason.decode!()
      |> Map.put("runtime_ref", delivery.runtime_ref)

    %{payload: payload}
  end

  test "missing reports are distinct from zero activity; fresh and stale observations remain labelled",
       %{conn: conn, payload: payload} do
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    assert has_element?(view, "#delivery-hook-assistant-client-runtime-missing")
    assert {:ok, _} = Hub.client_runtime_report("ai-token", payload)
    send(view.pid, :refresh_request_activity)

    assert has_element?(
             view,
             "#delivery-hook-assistant-client-runtime-freshness[data-status=fresh]"
           )

    assert has_element?(view, "#delivery-hook-assistant-client-runtime-active", "2")
    assert has_element?(view, "#delivery-hook-assistant-client-runtime-overdue", "1")
    assert has_element?(view, "#delivery-hook-assistant-client-runtime-quarantine", "3")
    assert has_element?(view, "#delivery-hook-assistant-client-runtime-reported time[datetime]")

    :sys.replace_state(Hub, fn s ->
      update_in(
        s.delivery.client_presence["assistant"].runtime_report.received_ms,
        &(&1 - 20_000)
      )
    end)

    send(view.pid, :refresh_request_activity)

    assert has_element?(
             view,
             "#delivery-hook-assistant-client-runtime-freshness[data-status=stale]"
           )

    assert has_element?(view, "#delivery-hook-assistant-client-runtime-active", "2")
    assert has_element?(view, "#delivery-hook-assistant-client-runtime", "Last observation only")
  end

  test "pause freezes client reports and resume refreshes phase and quarantine availability", %{
    conn: conn,
    payload: payload
  } do
    assert {:ok, _} = Hub.client_runtime_report("ai-token", payload)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    view |> element("#exiron-toggle-live") |> render_click()
    next = %{payload | "sequence" => 2, "phase" => "draining", "quarantine_available" => false}
    assert {:ok, _} = Hub.client_runtime_report("ai-token", next)
    send(view.pid, :refresh_request_activity)
    assert has_element?(view, "#delivery-hook-assistant-client-runtime-phase", "handling")
    view |> element("#exiron-toggle-live") |> render_click()
    assert has_element?(view, "#delivery-hook-assistant-client-runtime-phase", "draining")
    assert has_element?(view, "#delivery-hook-assistant-client-runtime-quarantine", "Unavailable")
    current = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", "worker", current.lease})
    _ = :sys.get_state(Hub)
    send(view.pid, :refresh_request_activity)

    assert has_element?(
             view,
             "#delivery-hook-assistant-client-runtime-freshness[data-status=session_inactive]"
           )
  end
end
