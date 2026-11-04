defmodule ExironWeb.PageLiveTest do
  use ExironWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Exiron.Hub
  alias Exiron.Hub.Message
  alias Exiron.Hub.Telegram
  import Exiron.Support.RouterHelper

  setup do
    router = load_router!()
    :ok = Hub.configure(router, Telegram.new([]))
    :ok
  end

  test "GET /", %{conn: conn} do
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#primary-navigation")
    assert has_element?(view, "#nav-overview[aria-current=page]")
    assert has_element?(view, "#theme-controls")

    assert has_element?(
             view,
             "#logout-link .hero-arrow-right-start-on-rectangle-micro"
           )

    assert has_element?(view, "#exiron-overview")
    assert has_element?(view, "#control-plane-overview")
    assert has_element?(view, "#overview-title")
    refute has_element?(view, "#control-plane-overview a")
    assert has_element?(view, "#exiron-hooks")
    assert has_element?(view, "#exiron-hook-stream[phx-update=stream]")
    assert has_element?(view, "#exiron-routes")
    assert has_element?(view, "#exiron-route-stream[phx-update=stream]")
    assert has_element?(view, "#exiron-client-events")
    assert has_element?(view, "#exiron-client-event-stream[phx-update=stream]")
    assert has_element?(view, "#exiron-messages")
    assert has_element?(view, "#exiron-message-stream[phx-update=stream]")

    assert has_element?(
             view,
             ~s(#exiron-connected-count[aria-label="0 active of 1 total hooks"])
           )

    assert has_element?(view, "#exiron-requested-count", "0")
    assert has_element?(view, "#exiron-telegram-polling-status", "polling")
    assert has_element?(view, "#exiron-telegram-last-polled", "Last poll: never")
  end

  test "shows when Telegram polling is disabled", %{conn: conn} do
    hub_config = Application.get_env(:exiron, :hub, [])
    Application.put_env(:exiron, :hub, Keyword.put(hub_config, :telegram_pollers_enabled, false))

    on_exit(fn ->
      Application.put_env(:exiron, :hub, hub_config)
    end)

    :ok = Hub.configure(load_router!(), Telegram.new([]))
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exiron-telegram-polling-status", "not polling")
  end

  test "updates hub status from pubsub without reloading the page", %{conn: conn} do
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exiron-connected-count", "0")

    assert {:ok, []} = Hub.poll("ai-token", client_id: "dashboard-client")

    assert has_element?(
             view,
             ~s(#exiron-connected-count[aria-label="1 active of 1 total hooks"])
           )

    assert has_element?(view, "#exiron-client-events", "connected")
    assert has_element?(view, "#exiron-client-events", "client: dashboard-client")

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-requested-count", "1")
      assert has_element?(view, "#exiron-messages", "incoming")
      assert has_element?(view, "#exiron-messages", "forward")
    end)

    expire_client("assistant", "dashboard-client")

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-connected-count", "0")
      assert has_element?(view, "#exiron-client-events", "disconnected")
    end)
  end

  test "updates Telegram last poll time from pollers", %{conn: conn} do
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exiron-telegram-last-polled", "Last poll: never")

    start_poller!(get_updates: fn _options -> {:ok, []} end)

    assert_eventually(fn ->
      refute has_element?(view, "#exiron-telegram-last-polled", "Last poll: never")
      assert has_element?(view, "#exiron-telegram-last-polled", "Last poll:")
    end)
  end

  test "shows full file and photo captions on initial load and live updates", %{conn: conn} do
    caption = "<b>Document & details</b>\n" <> String.duplicate("caption text ", 30)

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "file", "file bytes", nil, caption: caption)
      )

    {:ok, view, _html} = live(log_in(conn), ~p"/")
    [file_event | _] = Hub.status().events
    file_selector = "#exiron-event-caption-#{file_event.id}"
    assert has_element?(view, file_selector, "Document & details")

    assert has_element?(
             view,
             "#{file_selector} .whitespace-pre-wrap",
             String.duplicate("caption text ", 30) |> String.trim()
           )

    refute has_element?(view, "#{file_selector} b")

    png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "image bytes">>

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "image", png, nil, caption: "Photo caption")
      )

    [photo_event | _] = Hub.status().events

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-event-image-#{photo_event.id}")
      assert has_element?(view, "#exiron-event-caption-#{photo_event.id}", "Photo caption")
      assert has_element?(view, file_selector)
    end)
  end

  test "omits caption blocks for files without captions", %{conn: conn} do
    for caption <- [nil, ""] do
      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "file", "bytes", nil, caption: caption)
        )
    end

    {:ok, view, _html} = live(log_in(conn), ~p"/")
    assert has_element?(view, "#exiron-message-stream", "file payload, 5 bytes")
    refute has_element?(view, "[id^=exiron-event-caption-]")
  end

  test "shows image previews for image messages", %{conn: conn} do
    conn = log_in(conn)
    png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "image bytes">>

    {:ok, view, _html} = live(conn, ~p"/")

    :ok = Hub.incoming_service_message(Message.new(222, 123, "image", png, "bot-token"))

    assert_eventually(fn ->
      assert has_element?(view, ~s(img[alt="Message image preview"]))
    end)
  end

  test "shows Telegram message references for messages", %{conn: conn} do
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai hello", "bot-token",
          bot_name: "assistant-bot",
          message_id: 1234,
          reply_to_message_id: 1201
        )
      )

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-messages", "bot: assistant-bot")
      assert has_element?(view, "#exiron-messages", "msg: 1234")
      assert has_element?(view, "#exiron-messages", "reply: 1201")
    end)
  end

  test "shows sticker ids and emoji for sticker messages", %{conn: conn} do
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "sticker", "sticker-file-id", "bot-token",
          sticker_emoji: "\u{1F525}"
        )
      )

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-messages", "sticker: sticker-file-id")
      assert has_element?(view, "#exiron-messages", "emoji: \u{1F525}")
      assert has_element?(view, "#exiron-messages", "emoji list: \u{1F525} \u{1F4AF}")
    end)
  end

  defp load_router! do
    load_router!("page-live")
  end

  defp start_poller!(opts) do
    parent = self()
    poll_count = start_supervised!({Agent, fn -> 0 end})

    get_updates =
      Keyword.get(opts, :get_updates, fn _options ->
        {:ok, []}
      end)

    wrapped_get_updates = fn options ->
      Agent.get_and_update(poll_count, fn
        0 ->
          send(parent, :polled)
          {get_updates.(options), 1}

        count ->
          {{:error, :done}, count + 1}
      end)
    end

    pid =
      start_supervised!(
        {Exiron.Hub.Telegram.Poller, token: "bot-token", get_updates: wrapped_get_updates}
      )

    assert_receive :polled
    GenServer.stop(pid)
  end

  defp expire_client(hook, client_id) do
    %{client_id: ^client_id, lease: lease} = :sys.get_state(Hub).delivery.clients[hook]
    send(Hub, {:expire_client, hook, client_id, lease})
    _ = :sys.get_state(Hub)
  end
end
