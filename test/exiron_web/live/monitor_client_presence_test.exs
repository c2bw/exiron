defmodule ExironWeb.MonitorClientPresenceTest do
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

    :ok
  end

  test "shows HTTP work and last contact without claiming an expired lease is a disconnect", %{
    conn: conn
  } do
    {:ok, []} = Hub.poll("ai-token", client_id: "slow-worker")
    id = incoming()
    {:ok, [_]} = Hub.poll("ai-token", client_id: "slow-worker")
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    assert has_element?(view, "#delivery-hook-assistant-client-identity", "slow-worker")
    assert has_element?(view, "#delivery-hook-assistant-client-work", "1 awaiting response")
    assert has_element?(view, "#delivery-hook-assistant-client-last-contact time[datetime]")
    view |> element("#request-trace-#{id}-inspect") |> render_click()
    assert has_element?(view, "#exiron-request-client-state[data-state=http_polling]")
    client = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", client.client_id, client.lease})
    _ = :sys.get_state(Hub)

    assert_eventually(fn ->
      assert has_element?(
               view,
               "#delivery-hook-assistant-client-state[data-state=http_lease_expired]",
               "No recent HTTP poll"
             )

      assert has_element?(
               view,
               "#exiron-request-client-explanation",
               "does not prove a disconnect"
             )

      assert has_element?(
               view,
               "#request-trace-#{id}-client-state[data-state=http_lease_expired]"
             )
    end)

    assert has_element?(view, "#delivery-hook-assistant-availability", "Available")
    refute has_element?(view, "#request-trace-#{id}[data-attention=client_disconnected]")
  end

  test "observed socket disconnects mark waiting requests and pause freezes client details", %{
    conn: conn
  } do
    socket = Exiron.HubCase.start_socket_process()
    {:ok, _} = Hub.connect_socket("ai-token", client_id: "socket-worker", pid: socket)
    id = incoming()
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    view |> element("#request-trace-#{id}-inspect") |> render_click()
    assert has_element?(view, "#exiron-request-client-state[data-state=websocket_connected]")
    view |> element("#exiron-toggle-live") |> render_click()
    :ok = Hub.disconnect_socket("assistant", "socket-worker", socket)
    send(view.pid, :refresh_request_activity)
    assert has_element?(view, "#exiron-request-client-state[data-state=websocket_connected]")
    view |> element("#exiron-toggle-live") |> render_click()

    assert has_element?(
             view,
             "#delivery-hook-assistant-client-state[data-state=websocket_disconnected]"
           )

    assert has_element?(view, "#exiron-request-client-state[data-state=websocket_disconnected]")
    assert has_element?(view, "#request-trace-#{id}[data-attention=client_disconnected]")
  end

  test "the monitor clock refreshes last contact without requiring a status publication", %{
    conn: conn
  } do
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    changed = ~U[2026-10-27 13:00:00Z]

    :sys.replace_state(Hub, fn state ->
      put_in(state.delivery.client_presence["assistant"].last_contact_at, changed)
    end)

    send(view.pid, :refresh_request_activity)

    assert_eventually(fn ->
      assert has_element?(
               view,
               "#delivery-hook-assistant-client-last-contact time[datetime='2026-10-27T13:00:00Z']"
             )
    end)
  end

  defp incoming do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request", bot_token: "bot-token")
      )

    hd(Hub.request_traces()).id
  end
end
