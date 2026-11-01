defmodule ExironWeb.HandlerReportTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{HookToken, Message, Telegram}

  setup do
    router = Exiron.HubCase.load_router!()
    router = %{router | hooks: Map.put(router.hooks, "other", HookToken.hash("other-token"))}

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:ok, %{message_id: 901}} end
        )
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hi", "bot-token"))

    {:ok, %{delivery_id: batch, requests: [request]}} =
      Hub.poll_delivery("ai-token", client_id: "worker")

    payload = %{
      "req_id" => request.req_id,
      "client_id" => "worker",
      "delivery_id" => batch,
      "attempt" => 1,
      "max_attempts" => 3,
      "state" => "retrying",
      "category" => "handler_error"
    }

    %{payload: payload, id: request.req_id, batch: batch}
  end

  test "reports are bounded diagnostics, not acknowledgements or lease renewal", %{
    conn: conn,
    payload: payload,
    id: id
  } do
    before = :sys.get_state(Hub)
    assert report(conn, payload) |> json_response(200) == %{"ok" => true}
    after_state = :sys.get_state(Hub)
    assert before.delivery == after_state.delivery
    assert %{status: :handler_retrying, handler: %{"attempt" => 1}} = Hub.request_trace(id)
    revision = after_state.activity.trace_revision
    assert report(conn, payload) |> json_response(200) == %{"ok" => true}
    assert :sys.get_state(Hub).activity.trace_revision == revision
    exhausted = %{payload | "attempt" => 3, "state" => "exhausted"}
    assert report(conn, exhausted) |> json_response(200) == %{"ok" => true}
    assert %{status: :handler_exhausted, pending?: true} = Hub.request_trace(id)
    assert report(conn, payload) |> json_response(200) == %{"ok" => true}
    assert %{status: :handler_exhausted} = Hub.request_trace(id)
  end

  test "recovery clears reported failure and late reports never reopen completed work", %{
    conn: conn,
    payload: payload,
    id: id
  } do
    assert {:ok, _} = Hub.handler_report("ai-token", payload)

    recovered =
      payload |> Map.merge(%{"attempt" => 2, "state" => "recovered"}) |> Map.delete("category")

    assert report(conn, recovered) |> json_response(200) == %{"ok" => true}

    assert %{status: :awaiting_response, handler: %{"state" => "recovered"}} =
             Hub.request_trace(id)

    assert :ok = Hub.respond("ai-token", id, "text", "done")

    assert report(conn, %{payload | "attempt" => 3, "state" => "exhausted"}) |> json_response(200) ==
             %{"ok" => true}

    assert %{status: :completed, pending?: false} = Hub.request_trace(id)
  end

  test "ownership and batch checks reject forged or stale reports", %{
    conn: conn,
    payload: payload,
    batch: batch
  } do
    assert conn
           |> put_req_header("authorization", "Bearer other-token")
           |> post("/api/handler-reports", payload)
           |> json_response(409)

    for invalid <- [%{payload | "client_id" => "other"}, %{payload | "delivery_id" => "old"}] do
      assert report(conn, invalid) |> json_response(409)
    end

    assert {:ok, _} = Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: batch)
    assert report(conn, payload) |> json_response(409)
    assert post(conn, "/api/handler-reports", payload) |> json_response(401)
  end

  test "arbitrary detail and invalid attempt combinations are rejected", %{
    conn: conn,
    payload: payload
  } do
    for invalid <- [
          Map.put(payload, "error", "secret body"),
          %{payload | "category" => "secret"},
          %{payload | "attempt" => 0},
          %{payload | "max_attempts" => 11},
          %{payload | "attempt" => 3},
          %{payload | "state" => "exhausted"},
          %{payload | "state" => "recovered"},
          Map.put(payload, "req_id", ["bad"])
        ] do
      assert report(conn, invalid) |> json_response(400)
    end
  end

  test "evicted traces are never recreated", %{conn: conn, payload: payload} do
    :sys.replace_state(Hub, fn state ->
      %{state | activity: %{state.activity | traces: %{}, trace_order: []}}
    end)

    assert report(conn, payload) |> json_response(404)
    assert Hub.request_traces() == []
  end

  defp report(conn, payload),
    do:
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post("/api/handler-reports", payload)
end
