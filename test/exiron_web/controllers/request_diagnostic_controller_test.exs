defmodule ExironWeb.RequestDiagnosticControllerTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: fn _, _ -> :ok end)
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "private-worker")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(Telegram.service_id(), 123, "text", "/ai PRIVATE-BODY",
          bot_token: "bot-token",
          message_id: 77,
          from: %{id: 424_242}
        )
      )

    [trace] = Hub.request_traces()
    %{trace: trace}
  end

  test "diagnostic downloads require dashboard authentication", %{conn: conn, trace: trace} do
    conn = get(conn, "/diagnostics/requests/#{trace.id}")
    assert redirected_to(conn) == "/login"
  end

  test "JSON download contains sanitized timeline and cache prevention", %{
    conn: conn,
    trace: trace
  } do
    conn = conn |> log_in() |> get("/diagnostics/requests/#{trace.id}")
    body = json_response(conn, 200)
    assert body["request"]["status"] == "queued"
    assert Enum.map(body["timeline"], & &1["kind"]) == ["received", "route_selected", "queued"]

    for value <- ["PRIVATE-BODY", "private-worker", "bot-token", "ai-token", "424242", trace.id] do
      refute conn.resp_body =~ value
    end

    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="exiron-request-diagnostic.json")
           ]
  end

  test "missing or evicted diagnostics return 404", %{conn: conn} do
    conn = conn |> log_in() |> get("/diagnostics/requests/no-longer-retained")
    assert json_response(conn, 404)["error"]
  end
end
