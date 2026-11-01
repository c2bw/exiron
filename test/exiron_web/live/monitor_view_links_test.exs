defmodule ExironWeb.MonitorViewLinksTest do
  use ExironWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:ok, %{message_id: 99}} end
        )
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "inspector")
    :ok = incoming(1)
    {:ok, [completed]} = Hub.poll("ai-token", client_id: "inspector")
    :ok = Hub.respond("ai-token", completed.req_id, "text", "answer")
    :ok = incoming(2)
    {:ok, [active]} = Hub.poll("ai-token", client_id: "inspector")
    %{completed: completed.req_id, active: active.req_id}
  end

  test "all filters and selected request survive a fresh URL load", %{
    conn: conn,
    completed: id,
    active: active
  } do
    query = %{
      "hook" => "assistant",
      "chat" => "123",
      "client" => "inspector",
      "request" => id,
      "outcome" => "completed",
      "range" => "1h",
      "inspect" => id
    }

    path = "/monitor?" <> Plug.Conn.Query.encode(query)
    {:ok, view, _} = live(log_in(conn), path)
    assert has_element?(view, "#request-trace-#{id}")
    refute has_element?(view, "#request-trace-#{active}")
    assert has_element?(view, "#exiron-request-detail", id)
    assert has_element?(view, "#exiron-activity-range option[value='1h'][selected]")
    assert has_element?(view, "#activity_client[value=inspector]")
    assert link_query(view) == query
  end

  test "filter changes and inspection update the URL while closing retains filters", %{
    conn: conn,
    completed: id
  } do
    {:ok, view, _} = live(log_in(conn), "/monitor")

    params = %{
      hook: "assistant",
      chat: "123",
      client: "inspector",
      outcome: "completed",
      range: "5m",
      request: ""
    }

    form(view, "#exiron-activity-filters", activity: params) |> render_change()
    path = assert_patch(view)

    assert URI.parse(path).query |> Plug.Conn.Query.decode() == %{
             "hook" => "assistant",
             "chat" => "123",
             "client" => "inspector",
             "outcome" => "completed",
             "range" => "5m"
           }

    view |> element("#request-trace-#{id}-inspect") |> render_click()
    selected = assert_patch(view)
    assert Plug.Conn.Query.decode(URI.parse(selected).query)["inspect"] == id
    view |> element("#exiron-close-request") |> render_click()
    closed = assert_patch(view)
    refute Map.has_key?(Plug.Conn.Query.decode(URI.parse(closed).query), "inspect")
    assert has_element?(view, "#exiron-activity-hook option[value=assistant][selected]")
    form(view, "#exiron-activity-filters", activity: %{client: "ID & stuff"}) |> render_change()
    escaped = assert_patch(view)
    assert Plug.Conn.Query.decode(URI.parse(escaped).query)["client"] == "ID & stuff"
  end

  test "malformed filters normalize safely and stale selections do not select other records", %{
    conn: conn,
    completed: id
  } do
    {:ok, view, _} =
      live(
        log_in(conn),
        "/monitor?client[]=invalid&outcome=unknown&range=forever&inspect=missing"
      )

    refute has_element?(view, "#exiron-request-detail")
    assert link_query(view) == %{}
    {:ok, wrong, _} = live(log_in(conn), "/monitor?hook=unknown&inspect=#{id}")
    refute has_element?(wrong, "#exiron-request-detail")
  end

  test "URL inspection respects the paused snapshot", %{conn: conn} do
    {:ok, view, _} = live(log_in(conn), "/monitor")
    view |> element("#exiron-toggle-live") |> render_click()
    :ok = incoming(3)
    [latest | _] = Hub.request_traces()
    render_hook(view, "inspect_request", %{id: latest.id})
    _ = assert_patch(view)
    refute has_element?(view, "#exiron-request-detail")
    assert has_element?(view, "#exiron-live-paused")
  end

  defp incoming(id),
    do:
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai question", bot_token: "bot-token", message_id: id)
      )

  defp link_query(view) do
    [href] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#exiron-monitor-permalink")
      |> LazyHTML.attribute("href")

    Plug.Conn.Query.decode(URI.parse(href).query || "")
  end
end
