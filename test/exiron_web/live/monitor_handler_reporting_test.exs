defmodule ExironWeb.MonitorHandlerReportingTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok = Hub.configure(Exiron.HubCase.load_router!(), Telegram.new([]))
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello"))

    {:ok, %{delivery_id: batch, requests: [request]}} =
      Hub.poll_delivery("ai-token", client_id: "worker")

    payload = %{
      "req_id" => request.req_id,
      "client_id" => "worker",
      "delivery_id" => batch,
      "attempt" => 1,
      "max_attempts" => 2,
      "state" => "retrying",
      "category" => "handler_error"
    }

    %{id: request.req_id, payload: payload}
  end

  test "reported retries, exhaustion and recovery appear in activity and details", %{
    conn: conn,
    id: id,
    payload: payload
  } do
    {:ok, view, _} = live(log_in(conn), ~p"/monitor")
    {:ok, _} = Hub.handler_report("ai-token", payload)
    assert has_element?(view, "#request-trace-#{id}[data-outcome=handler_retrying]")
    assert has_element?(view, "#request-trace-#{id}-handler[data-state=retrying]")
    view |> element("#request-trace-#{id}-inspect") |> render_click()
    assert has_element?(view, "#exiron-handler-report[data-state=retrying]", "attempt 1/2")
    {:ok, _} = Hub.handler_report("ai-token", %{payload | "attempt" => 2, "state" => "exhausted"})
    assert has_element?(view, "#request-trace-#{id}[data-outcome=handler_exhausted]")
    assert has_element?(view, "#exiron-handler-report[data-state=exhausted]")

    view
    |> form("#exiron-activity-filters", activity: %{outcome: "handler_exhausted"})
    |> render_change()

    assert has_element?(view, "#request-trace-#{id}")
    # Lease expiry requeues delivery, but must not hide the last failure report.
    client = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", client.client_id, client.lease})
    _ = Hub.status()
    assert has_element?(view, "#request-trace-#{id}[data-outcome=queued]")
    assert has_element?(view, "#request-trace-#{id}-handler[data-state=exhausted]")
  end

  test "paused reports remain frozen until resume", %{conn: conn, id: id, payload: payload} do
    {:ok, view, _} = live(log_in(conn), ~p"/monitor")
    view |> element("#exiron-toggle-live") |> render_click()
    {:ok, _} = Hub.handler_report("ai-token", payload)
    refute has_element?(view, "#request-trace-#{id}-handler")
    view |> element("#exiron-toggle-live") |> render_click()
    assert has_element?(view, "#request-trace-#{id}-handler[data-state=retrying]")

    recovered =
      payload |> Map.merge(%{"attempt" => 2, "state" => "recovered"}) |> Map.delete("category")

    {:ok, _} = Hub.handler_report("ai-token", recovered)
    assert has_element?(view, "#request-trace-#{id}-handler[data-state=recovered]")
    assert has_element?(view, "#request-trace-#{id}[data-outcome=awaiting_response]")
  end
end
