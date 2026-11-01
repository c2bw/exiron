defmodule ExironWeb.MonitorRequestCancellationTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    parent = self()
    router = Exiron.HubCase.load_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "other", Exiron.Hub.HookToken.hash("other-token"))
    }

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, message ->
            send(parent, {:sent, message})
            {:ok, %{message_id: message.edit_message_id || 901}}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "the monitor requires dashboard authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/monitor")
  end

  test "queued requests can be cancelled and retained results remain inspectable", %{conn: conn} do
    id = incoming(1)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    inspect_request(view, id)
    assert has_element?(view, "#exiron-cancellation-delivery[data-delivery-status=not_started]")
    assert has_element?(view, "#exiron-cancel-request")
    refute has_element?(view, "#exiron-request-detail", "ai-token")
    refute has_element?(view, "#exiron-request-detail", "bot-token")
    view |> element("#exiron-cancel-request") |> render_click()
    assert has_element?(view, "#exiron-cancellation-result", "Request cancelled")
    assert has_element?(view, "#exiron-cancellation-message-ids", "None confirmed")
    refute has_element?(view, "#exiron-cancel-request")
    assert has_element?(view, "#request-trace-#{id}[data-outcome=cancelled]")
    assert {:ok, []} = Hub.poll("ai-token")
    assert {:error, :request_cancelled} = Hub.respond("ai-token", id, "text", "late")
    assert {:error, :request_not_assigned} = Hub.cancel("other-token", id)
    steps = Hub.request_trace(id).steps
    render_click(view, "cancel_request", %{"id" => id})
    assert Hub.request_trace(id).steps == steps
    view |> element("#exiron-close-request") |> render_click()
    inspect_request(view, id)
    assert has_element?(view, "#exiron-cancellation-result")
    assert Hub.request_trace(id).cancellation.message_ids == []
  end

  test "partial streaming delivery shows confirmed IDs before and after cancellation", %{
    conn: conn
  } do
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token")
    assert {:ok, _} = Hub.respond("ai-token", id, "text", "partial", final: false)
    assert_receive {:sent, _}
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    inspect_request(view, id)

    assert has_element?(
             view,
             "#exiron-cancellation-delivery[data-delivery-status=partial]",
             "Partially delivered"
           )

    assert has_element?(view, "#exiron-cancellation-message-ids", "901")
    view |> element("#exiron-cancel-request") |> render_click()
    assert has_element?(view, "#exiron-cancellation-result")
    assert has_element?(view, "#exiron-cancellation-delivery[data-delivery-status=partial]")
    assert has_element?(view, "#exiron-cancellation-message-ids", "901")
    assert {:error, :request_cancelled} = Hub.respond("ai-token", id, "text", "complete")
    refute_receive {:sent, _}
  end

  test "active multipart sends stop and report uncertainty without losing confirmed IDs", %{
    conn: conn
  } do
    parent = self()

    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, message ->
            send(parent, {:part, message.delivery_index, self()})

            if message.delivery_index == 1 do
              {:ok, %{message_id: 901}}
            else
              receive do
                :release -> {:ok, %{message_id: 902}}
              end
            end
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token")

    task =
      start_supervised!(
        {Task,
         fn ->
           send(
             parent,
             {:result,
              Hub.respond("ai-token", id, "text", String.duplicate("x", 8193),
                parse_mode: "plain"
              )}
           )
         end}
      )

    monitor = Process.monitor(task)
    assert_receive {:part, 1, _}
    assert_receive {:part, 2, worker}
    worker_monitor = Process.monitor(worker)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    inspect_request(view, id)

    assert has_element?(
             view,
             "#exiron-cancellation-delivery[data-delivery-status=unknown]",
             "Uncertain"
           )

    assert has_element?(view, "#exiron-cancellation-message-ids", "901")
    view |> element("#exiron-cancel-request") |> render_click()
    assert_receive {:result, {:error, :request_cancelled}}
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    assert has_element?(view, "#exiron-cancellation-result", "Delivery remains uncertain")
    assert has_element?(view, "#exiron-cancellation-message-ids", "901")
    refute_receive {:part, 3, _}
    assert Hub.status().delivery_health.in_flight_sends == 0
  end

  test "paused and unrelated request actions are rejected", %{conn: conn} do
    id = incoming(1)
    other = incoming(2)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    inspect_request(view, id)
    render_click(view, "cancel_request", %{"id" => other})
    assert has_element?(view, "#flash-error", "Inspect the request")
    assert Hub.request_trace(other).pending?
    view |> element("#exiron-toggle-live") |> render_click()
    assert has_element?(view, "#exiron-cancel-request[disabled]")
    render_click(view, "cancel_request", %{"id" => id})
    assert has_element?(view, "#flash-error", "Resume live updates")
    assert Hub.request_trace(id).pending?
    view |> element("#exiron-toggle-live") |> render_click()
    view |> element("#exiron-cancel-request") |> render_click()
    refute Hub.request_trace(id).pending?
    assert Hub.request_trace(other).pending?
  end

  test "completion winning a race is refreshed without claiming cancellation", %{conn: conn} do
    id = incoming(1)
    {:ok, [_]} = Hub.poll("ai-token")
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    inspect_request(view, id)
    assert :ok = Hub.respond("ai-token", id, "text", "completed")
    render_click(view, "cancel_request", %{"id" => id})
    assert has_element?(view, "#flash-error", "Nothing was cancelled")
    assert has_element?(view, "#request-trace-#{id}[data-outcome=completed]")
    refute has_element?(view, "#exiron-cancellation-result")
    refute has_element?(view, "#exiron-cancel-request")
  end

  test "expiry winning the race is not presented as a successful cancellation", %{conn: conn} do
    id = incoming(1)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    inspect_request(view, id)
    send(Hub, {:expire_request, id})
    assert Hub.request_trace(id).status == :expired
    render_click(view, "cancel_request", %{"id" => id})
    assert has_element?(view, "#flash-error", "Nothing was cancelled")
    assert has_element?(view, "#request-trace-#{id}[data-outcome=expired]")
    refute has_element?(view, "#exiron-cancellation-result")
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

  defp inspect_request(view, id),
    do: view |> element("#request-trace-#{id}-inspect") |> render_click()
end
