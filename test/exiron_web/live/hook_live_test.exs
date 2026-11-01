defmodule ExironWeb.HookLiveTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: fn _, _ -> :ok end)
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok
  end

  test "workspace requires dashboard login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/hooks/assistant")
  end

  test "workspace scopes activity and links requests to monitor inspection", %{conn: conn} do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(Telegram.service_id(), 123, "text", "/ai hello",
          bot_token: "bot-token",
          message_id: 1
        )
      )

    [trace] = Hub.request_traces()
    {:ok, view, _} = live(log_in(conn), "/hooks/assistant")
    assert has_element?(view, "#hook-availability[data-connected=true]")
    assert has_element?(view, "#hook-queued[data-value='1']")
    assert has_element?(view, "#hook-request-#{trace.id}")
    assert has_element?(view, "#hook-client-identity")
    assert has_element?(view, "#hook-routes [id^=hook-route-]")

    {:ok, monitor, _} =
      view
      |> element("#hook-request-#{trace.id}-inspect")
      |> render_click()
      |> follow_redirect(log_in(conn))

    assert has_element?(monitor, "#exiron-request-detail")

    assert has_element?(
             monitor,
             "#exiron-export-request[href='/diagnostics/requests/#{trace.id}']"
           )
  end

  test "failed sends explain the problem and open the exact retained delivery", %{conn: conn} do
    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ ->
            {:error, %ExGram.Error{code: 403, message: "PRIVATE-FAILURE-TEXT"}}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai hello", bot_token: "bot-token", message_id: 1)
      )

    {:ok, [request]} = Hub.poll("ai-token", client_id: "worker")
    assert {:error, _} = Hub.respond("ai-token", request.req_id, "text", "answer")
    [failure] = Hub.status().send_failures
    {:ok, view, _} = live(log_in(conn), "/hooks/assistant")

    assert has_element?(
             view,
             "#hook-failure-#{failure.id}-summary",
             "Bot cannot access this chat"
           )

    refute has_element?(view, "#hook-failures", "PRIVATE-FAILURE-TEXT")

    {:ok, monitor, _} =
      view
      |> element("#hook-failure-#{failure.id}-delivery")
      |> render_click()
      |> follow_redirect(log_in(conn))

    assert has_element?(monitor, "#exiron-delivery-diagnostics")
    assert has_element?(monitor, "#exiron-delivery-error", "Telegram 403")
    {:ok, missing, _} = live(log_in(conn), "/monitor?hook=assistant&delivery=no-longer-retained")
    refute has_element?(missing, "#exiron-delivery-diagnostics")
  end

  test "workspace refreshes new activity and clears a removed hook", %{conn: conn} do
    {:ok, view, _} = live(log_in(conn), "/hooks/assistant")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(Telegram.service_id(), 123, "text", "/ai hello",
          bot_token: "bot-token",
          message_id: 1
        )
      )

    [trace] = Hub.request_traces()
    send(view.pid, :request_traces_changed)
    assert has_element?(view, "#hook-request-#{trace.id}")
    {:ok, router} = Exiron.Hub.Router.load_definitions(%{})
    :ok = Hub.configure(router)
    send(view.pid, :request_traces_changed)
    assert has_element?(view, "#hook-not-found")
    refute has_element?(view, "#hook-requests")
  end
end
