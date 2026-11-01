defmodule ExironWeb.MonitorRequestActivityTest do
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

    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "all retained matches are browsable beyond the former 100-row cutoff", %{conn: conn} do
    requests =
      for n <- 1..120 do
        :ok =
          Hub.incoming_service_message(
            Message.incoming(222, 123, "text", "/ai request #{n}",
              bot_token: "bot-token",
              message_id: n
            )
          )

        {:ok, [req]} = Hub.poll("ai-token")
        req
      end

    oldest = hd(requests)
    newest = List.last(requests)
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")

    assert has_element?(
             view,
             "#exiron-request-scroll[tabindex='0'][role=region][phx-hook=RequestActivityScroll]"
           )

    assert has_element?(
             view,
             "#exiron-request-traces[phx-update=stream] > article:nth-of-type(120)"
           )

    refute has_element?(view, "#exiron-request-traces > article:nth-of-type(121)")
    assert has_element?(view, "#request-trace-#{oldest.req_id}")
    assert has_element?(view, "#request-trace-#{newest.req_id}")
    assert has_element?(view, "#exiron-request-scroll-hint")
    view |> element("#request-trace-#{oldest.req_id}-inspect") |> render_click()
    assert has_element?(view, "#exiron-request-detail", oldest.req_id)

    view
    |> form("#exiron-activity-filters", activity: %{request: oldest.req_id})
    |> render_change()

    assert has_element?(view, "#request-trace-#{oldest.req_id}")
    refute has_element?(view, "#request-trace-#{newest.req_id}")
    view |> form("#exiron-activity-filters", activity: %{request: ""}) |> render_change()
    assert has_element?(view, "#exiron-request-traces > article:nth-of-type(120)")
  end

  test "hook and chat dropdowns include known destinations and filter exact identities", %{
    conn: conn
  } do
    router =
      Exiron.Support.RouterHelper.load_router!("activity-dropdowns", """
      aliases:
        telegram:
          home: 123
          office: 1234
          unused: 5678
      routes:
        home:
          middleware: [family]
        office:
          middleware: [work]
        unused:
          middleware: [idle]
      middlewares:
        family:
          routes:
            assistant:
              messages: ["/ai"]
        work:
          routes:
            assistant-extra:
              messages: ["/work"]
        idle:
          routes:
            idle:
              messages: ["/idle"]
      hooks:
        assistant: "ai-token"
        assistant-extra: "extra-token"
        idle: "idle-token"
      """)

    :ok =
      Hub.configure(
        router,
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "bot-token"},
            %{chat_id: 1234, bot_token: "office-token"}
          ],
          sender: fn _, _ -> :ok end
        )
      )

    requests =
      for {token, chat, bot, text} <- [
            {"ai-token", 123, "bot-token", "/ai first"},
            {"extra-token", 1234, "office-token", "/work second"}
          ] do
        {:ok, []} = Hub.poll(token)

        :ok =
          Hub.incoming_service_message(Message.incoming(222, chat, "text", text, bot_token: bot))

        {:ok, [req]} = Hub.poll(token)
        req
      end

    [first, second] = requests
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    assert has_element?(view, "select#exiron-activity-hook option[value='']", "All hooks")
    assert has_element?(view, "select#exiron-activity-hook option[value=idle]", "idle")
    assert has_element?(view, "select#exiron-activity-chat option[value='123']", "home (123)")
    assert has_element?(view, "select#exiron-activity-chat option[value='1234']", "office (1234)")
    assert has_element?(view, "select#exiron-activity-chat option[value='5678']", "unused (5678)")
    refute has_element?(view, "input[name='activity[hook]']")
    refute has_element?(view, "input[name='activity[chat]']")
    view |> form("#exiron-activity-filters", activity: %{hook: "assistant"}) |> render_change()
    assert has_element?(view, "#request-trace-#{first.req_id}")
    refute has_element?(view, "#request-trace-#{second.req_id}")

    view
    |> form("#exiron-activity-filters", activity: %{hook: "", chat: "123"})
    |> render_change()

    assert has_element?(view, "#request-trace-#{first.req_id}")
    refute has_element?(view, "#request-trace-#{second.req_id}")
    view |> form("#exiron-activity-filters", activity: %{chat: "1234"}) |> render_change()
    refute has_element?(view, "#request-trace-#{first.req_id}")
    assert has_element?(view, "#request-trace-#{second.req_id}")

    view
    |> form("#exiron-activity-filters", activity: %{hook: "idle", chat: ""})
    |> render_change()

    refute has_element?(view, "#exiron-request-traces article")
    assert has_element?(view, "#exiron-activity-chat option[value='123']")
    view |> form("#exiron-activity-filters", activity: %{hook: "", chat: ""}) |> render_change()
    assert has_element?(view, "#request-trace-#{first.req_id}")
    assert has_element?(view, "#request-trace-#{second.req_id}")
  end

  test "known dropdown choices freeze while paused and refresh on resume", %{conn: conn} do
    {:ok, view, _} = conn |> log_in() |> live(~p"/monitor")
    view |> element("#exiron-toggle-live") |> render_click()
    router = Exiron.HubCase.load_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "new-hook", Exiron.Hub.HookToken.hash("new-token"))
    }

    :ok =
      Hub.configure(
        router,
        Telegram.new([
          %{chat_id: 123, bot_token: "bot-token"},
          %{chat_id: 999, bot_token: "new-bot"}
        ])
      )

    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#exiron-activity-hook option[value='new-hook']")
    refute has_element?(view, "#exiron-activity-chat option[value='999']")
    view |> element("#exiron-toggle-live") |> render_click()
    assert has_element?(view, "#exiron-activity-hook option[value='new-hook']")
    assert has_element?(view, "#exiron-activity-chat option[value='999']", "999")
  end
end
