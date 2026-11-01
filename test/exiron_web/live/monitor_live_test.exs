defmodule ExironWeb.MonitorLiveTest do
  use ExironWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Exiron.Hub
  alias Exiron.Hub.Message
  alias Exiron.Hub.Telegram
  import Exiron.Support.RouterHelper

  setup do
    router =
      load_router!("monitor-live", """
      aliases:
        telegram:
          home: 123
      routes:
        home:
          default_bot: assistant-bot
          middleware:
            - family
      middlewares:
        family:
          routes:
            assistant:
              messages:
                - "/ai"
      hooks:
        assistant: "ai-token"
      """)

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "bot-token", bot_name: "assistant-bot"},
          %{chat_id: 123, bot_token: "backup-token", bot_name: "backup-bot"}
        ],
        sender: fn _token, _message -> :ok end
      )

    :ok = Hub.configure(router, telegram)
    :ok = Hub.telegram_polled("bot-token", :started)
    :ok = Hub.telegram_polled("backup-token", :started)
    _ = Hub.status()
    :ok
  end

  test "Telegram protection shows skipped attempts and a confirmed retry recovery", %{conn: conn} do
    recovered = start_supervised!({Agent, fn -> false end})

    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "primary-secret-token", bot_name: "primary"},
            %{chat_id: 123, bot_token: "backup-secret-token", bot_name: "backup"}
          ],
          sender: fn token, _ ->
            if token == "primary-secret-token" and not Agent.get(recovered, & &1),
              do: {:error, %ExGram.Error{code: 403}},
              else: {:ok, %{message_id: 901}}
          end
        )
      )

    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    assert has_element?(view, "#telegram-suppression-empty")
    assert {:ok, 1} = Hub.push("ai-token", "text", "hello", 123, bot: "primary")
    assert {:ok, 1} = Hub.push("ai-token", "text", "again", 123, bot: "primary")

    assert_eventually(fn ->
      assert has_element?(view, "#telegram-suppression-records article", "primary")
      assert has_element?(view, "#telegram-suppression-counters", "1 attempts skipped")
    end)

    snapshot = Hub.status()
    refute inspect(snapshot.telegram_suppression) =~ "secret-token"
    refute inspect(snapshot.suppressed_bots) =~ "secret-token"
    Agent.update(recovered, fn _ -> true end)

    :sys.replace_state(Exiron.Hub.Telegram.SendCoordinator, fn state ->
      entries =
        Map.new(state.rejection_cache.entries, fn {key, entry} ->
          {key, %{entry | until: System.monotonic_time(:millisecond) - 1}}
        end)

      %{state | rejection_cache: %{state.rejection_cache | entries: entries}}
    end)

    assert {:ok, 1} = Hub.push("ai-token", "text", "probe", 123, bot: "primary")

    assert_eventually(fn ->
      refute has_element?(view, "#telegram-suppression-records article")
      assert has_element?(view, "#telegram-suppression-counters", "1 confirmed recoveries")
      assert has_element?(view, "#telegram-suppression-last-recovery", "primary")
    end)

    {:ok, scoped} = Hub.status_for_token("ai-token")
    refute Map.has_key?(scoped, :telegram_suppression)
    refute Map.has_key?(scoped, :suppressed_bots)
  end

  test "monitor shows shared queue and unacknowledged usage with capacity rejections", %{
    conn: conn
  } do
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :sys.replace_state(Hub, &put_in(&1.settings.max_buffered_bytes, 8))
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    assert has_element?(view, "#delivery-buffer-progress[value='0'][max='8']")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hi"))
    {:ok, delivery} = Hub.poll_delivery("ai-token", client_id: "worker")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai no"))

    assert_eventually(fn ->
      assert has_element?(view, "#delivery-buffer-progress[value='8'][max='8']")
      assert has_element?(view, "#delivery-buffer-rejections", "1 requests rejected")
    end)

    {:ok, _} =
      Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: delivery.delivery_id)

    assert_eventually(fn ->
      assert has_element?(view, "#delivery-buffer-progress[value='0'][max='8']")
    end)
  end

  test "delivery health shows live hook capacity and rejected sends", %{conn: conn} do
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    assert has_element?(view, "#delivery-hook-assistant-send-capacity", "0 / 10 in flight")

    assert has_element?(
             view,
             "#delivery-hook-assistant-send-capacity-rejections",
             "0 send capacity"
           )

    parent = self()

    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ ->
            send(parent, {:blocked, self()})

            receive do
              :release -> {:ok, %{message_id: 901}}
            end
          end
        )
      )

    :sys.replace_state(Hub, fn s ->
      %{s | settings: %{s.settings | max_in_flight_sends_per_hook: 1}}
    end)

    task =
      start_supervised!(
        {Task, fn -> send(parent, {:result, Hub.push("ai-token", "text", "hold", 123)}) end}
      )

    monitor = Process.monitor(task)
    assert_receive {:blocked, worker}
    bytes = Exiron.Hub.SendBudget.payload_bytes("hold", [])
    assert {:error, :hook_send_queue_full} = Hub.push("ai-token", "text", "reject", 123)

    assert_eventually(fn ->
      assert has_element?(view, "#delivery-hook-assistant-send-capacity", "1 / 1 in flight")
      assert has_element?(view, "#delivery-send-byte-progress[value='#{bytes}']")
      assert has_element?(view, "#delivery-hook-assistant-send-bytes")

      assert has_element?(
               view,
               "#delivery-hook-assistant-send-capacity-rejections",
               "1 send capacity"
             )
    end)

    send(worker, :release)
    assert_receive {:result, {:ok, 1}}
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}

    assert_eventually(fn ->
      assert has_element?(view, "#delivery-hook-assistant-send-capacity", "0 / 1 in flight")
      assert has_element?(view, "#delivery-send-byte-progress[value='0']")
    end)
  end

  test "delivery details show confirmed parts, safe errors and explicit retry guidance", %{
    conn: conn
  } do
    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "assistant-bot"}],
        sender: fn _, message ->
          if byte_size(message.data) == 4096,
            do: {:ok, %{message_id: 901}},
            else: {:error, %ExGram.Error{code: 400, message: "private-body bot-token"}}
        end
      )

    :ok = Hub.configure(Exiron.HubCase.load_push_router!(), telegram)
    {:ok, []} = Hub.poll("ai-token")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request", bot_token: "bot-token")
      )

    {:ok, [req]} = Hub.poll("ai-token")

    assert {:error, :telegram_delivery_timeout} =
             Hub.respond(
               "ai-token",
               req.req_id,
               "text",
               String.duplicate("x", 4096) <> "private-body",
               parse_mode: "plain"
             )

    {:ok, view, _} = live(log_in(conn), ~p"/monitor")
    view |> element("#request-trace-#{req.req_id}-inspect") |> render_click()
    assert has_element?(view, "#exiron-delivery-diagnostics")
    assert has_element?(view, "#exiron-delivery-guidance", "Inspect the chat")
    assert has_element?(view, "#exiron-delivery-parts [data-status=confirmed]", "901")
    assert has_element?(view, "#exiron-delivery-parts [data-status=rejected]")
    assert has_element?(view, "#exiron-delivery-error", "400")
    refute has_element?(view, "#exiron-delivery-diagnostics", "private-body")
    refute has_element?(view, "#exiron-delivery-diagnostics", "bot-token")
    view |> element("#exiron-close-delivery") |> render_click()
    refute has_element?(view, "#exiron-delivery-diagnostics")
    [failure] = Hub.status().send_failures
    view |> element("#exiron-toggle-live") |> render_click()
    view |> element("#exiron-monitor-send-failure-#{failure.id}-delivery") |> render_click()
    assert has_element?(view, "#exiron-delivery-parts [data-status=confirmed]")
  end

  test "filters request traces, follows their lifecycle and freezes inspection while paused", %{
    conn: conn
  } do
    {:ok, _} = Hub.poll_delivery("ai-token", client_id: "inspector")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai private question", "bot-token", message_id: 42)
      )

    {:ok, %{requests: [request], delivery_id: ack}} =
      Hub.poll_delivery("ai-token", client_id: "inspector")

    {:ok, view, _} = live(log_in(conn), ~p"/monitor")
    row = "#request-trace-#{request.req_id}"
    assert has_element?(view, row)
    view |> element(row <> "-inspect") |> render_click()
    assert has_element?(view, "#exiron-request-detail", request.req_id)
    refute has_element?(view, "#exiron-request-detail", "private question")
    {:ok, _} = Hub.poll_delivery("ai-token", client_id: "inspector", delivery_ack: ack)

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-trace-steps [data-stage=client_acknowledged]")
    end)

    :ok = Hub.respond("ai-token", request.req_id, "text", "private answer")
    assert_eventually(fn -> assert has_element?(view, row <> "[data-outcome=completed]") end)
    view |> form("#exiron-activity-filters", activity: %{outcome: "expired"}) |> render_change()
    refute has_element?(view, row)

    view
    |> form("#exiron-activity-filters",
      activity: %{
        hook: "",
        chat: "123",
        client: "inspector",
        request: request.req_id,
        outcome: "completed"
      }
    )
    |> render_change()

    assert has_element?(view, row)

    view |> element("#exiron-toggle-live") |> render_click()
    assert has_element?(view, "#exiron-live-paused")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai another", "bot-token"))
    [new_request | _] = Hub.request_traces()
    send(view.pid, :request_traces_changed)
    _ = :sys.get_state(view.pid)

    view
    |> form("#exiron-activity-filters",
      activity: %{hook: "", chat: "", client: "", request: new_request.id, outcome: ""}
    )
    |> render_change()

    refute has_element?(view, "#request-trace-#{new_request.id}")
    view |> element("#exiron-toggle-live") |> render_click()
    refute has_element?(view, "#exiron-live-paused")
    assert has_element?(view, "#request-trace-#{new_request.id}")
  end

  test "shows configured chat bot and polling details", %{conn: conn} do
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/monitor")

    assert has_element?(view, "#nav-monitor[aria-current=page]")
    assert has_element?(view, "#exiron-monitor-chats")
    assert has_element?(view, "#exiron-monitor-chats-stream[phx-update=stream]")
    assert has_element?(view, "#exiron-monitor-chat-123")
    assert has_element?(view, "#exiron-monitor-chat-123-bot-memberships")
    assert has_element?(view, "#exiron-monitor-chat-123", "home")
    assert has_element?(view, "#exiron-monitor-chat-123-default-bot", "assistant-bot")
    assert has_element?(view, "#exiron-monitor-chat-123-current-bot", "assistant-bot")
    assert has_element?(view, "#exiron-monitor-chat-123-polling", "polling")
  end

  test "updates current bot from hub status events", %{conn: conn} do
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/monitor")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai hello", "backup-token", bot_name: "backup-bot")
      )

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-monitor-chat-123-current-bot", "backup-bot")
    end)
  end

  test "shows live offline rejection totals and client connection history", %{conn: conn} do
    {:ok, view, _html} = live(log_in(conn), ~p"/monitor")
    assert has_element?(view, "#exiron-delivery-health")
    assert has_element?(view, "#delivery-hooks[phx-update=stream]")
    assert has_element?(view, "#delivery-hook-assistant-availability", "Unavailable")
    assert has_element?(view, "#delivery-hook-assistant-connected", "Never")

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

    assert_eventually(fn ->
      assert has_element?(view, "#delivery-hook-assistant-rejections", "1 offline")
    end)

    assert {:ok, []} = Hub.poll("ai-token")

    assert_eventually(fn ->
      assert has_element?(view, "#delivery-hook-assistant-availability", "Available")
      assert has_element?(view, "#delivery-hook-assistant-connected time[datetime]")
    end)

    client = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", client.client_id, client.lease})

    assert_eventually(fn ->
      assert has_element?(view, "#delivery-hook-assistant-availability", "Unavailable")
      assert has_element?(view, "#delivery-hook-assistant-disconnected time[datetime]")
      assert has_element?(view, "#delivery-hook-assistant-rejections", "1 offline")
    end)
  end

  test "shows bot group add and remove events", %{conn: conn} do
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/monitor")

    assert has_element?(view, "#exiron-monitor-membership-event-stream[phx-update=stream]")
    assert has_element?(view, "#exiron-monitor-send-failure-stream[phx-update=stream]")

    Hub.telegram_membership_changed(%{
      action: "removed",
      chat_id: 123,
      chat_title: "Home",
      bot_token: "bot-token",
      bot_name: "assistant-bot",
      bot_user_id: 42,
      old_status: "member",
      new_status: "kicked"
    })

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-monitor-membership-events", "removed")
      assert has_element?(view, "#exiron-monitor-membership-events", "assistant-bot")
      assert has_element?(view, "#exiron-monitor-membership-events", "chat: 123")
      assert has_element?(view, "#exiron-monitor-membership-events", "group: Home")
      assert has_element?(view, "#exiron-monitor-membership-events", "member -> kicked")

      assert has_element?(
               view,
               "#exiron-monitor-chat-123-bot-memberships",
               "assistant-bot: kicked"
             )
    end)
  end

  test "shows failed Telegram push and reply sends", %{conn: conn} do
    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "assistant-bot"}],
        sender: fn _token, _message ->
          {:error, %ExGram.Error{code: 403, message: "Forbidden"}}
        end
      )

    :ok = Hub.configure(load_router!("monitor-live-failed-sends"), telegram)
    conn = log_in(conn)

    {:ok, view, _html} = live(conn, ~p"/monitor")

    assert {:ok, []} = Hub.poll("ai-token")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
    assert {:ok, [request]} = Hub.poll("ai-token")

    assert {:error, :telegram_bot_forbidden} =
             Hub.respond("ai-token", request.req_id, "text", "hello back")

    assert_eventually(fn ->
      assert has_element?(view, "#exiron-monitor-send-failures", "reply")
      assert has_element?(view, "#exiron-monitor-send-failures", "bot: assistant-bot")
      assert has_element?(view, "#exiron-monitor-send-failures", "chat: 123")
      assert has_element?(view, "#exiron-monitor-send-failures", "hello back")
      assert has_element?(view, "#exiron-monitor-send-failures", ":telegram_bot_forbidden")
    end)
  end
end
