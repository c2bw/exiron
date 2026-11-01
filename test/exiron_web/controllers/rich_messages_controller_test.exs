defmodule ExironWeb.RichMessagesControllerTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    parent = self()
    ids = start_supervised!({Agent, fn -> 70 end})
    router = Exiron.HubCase.load_router!()

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _token, message ->
            send(parent, {:sent, message})

            if message.datatype == "action" do
              :ok
            else
              {:ok,
               %{
                 message_id:
                   message.edit_message_id || Agent.get_and_update(ids, &{&1 + 1, &1 + 1})
               }}
            end
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai request", "bot-token", message_thread_id: 9)
      )

    {:ok, [request]} = Hub.poll("ai-token")
    %{request: request}
  end

  test "existing one-shot responses retain their exact success shape", %{
    conn: conn,
    request: request
  } do
    assert api(conn, "/api/responses", %{
             req_id: request.req_id,
             datatype: "text",
             data: Base.encode64("done")
           }) == %{"ok" => true}

    assert Hub.status().delivery_health.pending == 0
  end

  test "streaming, actions and later edits are additive authenticated operations", %{
    conn: conn,
    request: request
  } do
    assert api(conn, "/api/actions", %{req_id: request.req_id, action: "typing"}) == %{
             "ok" => true
           }

    assert_receive {:sent, %{datatype: "action", message_thread_id: 9}}

    assert api(conn, "/api/responses", %{
             req_id: request.req_id,
             datatype: "text",
             data: Base.encode64("partial"),
             final: false
           }) == %{"ok" => true, "final" => false, "message_id" => 71}

    assert Hub.status().delivery_health.pending == 1

    assert api(conn, "/api/responses", %{
             req_id: request.req_id,
             datatype: "text",
             data: Base.encode64("done")
           }) == %{"ok" => true}

    assert api(conn, "/api/edits", %{
             req_id: request.req_id,
             datatype: "text",
             data: Base.encode64("correction")
           }) == %{"ok" => true}
  end

  test "new operations require authentication", %{conn: conn, request: request} do
    for path <- ["/api/actions", "/api/edits"] do
      response =
        post(conn, path, %{
          req_id: request.req_id,
          action: "typing",
          datatype: "text",
          data: "eA=="
        })

      assert json_response(response, 401)["code"] == "missing_token"
    end
  end

  test "button replies and callback-origin keyboard edits flow through authenticated JSON", %{
    conn: conn,
    request: request
  } do
    assert api(conn, "/api/responses", %{
             req_id: request.req_id,
             datatype: "text",
             data: Base.encode64("Menu"),
             inline_keyboard: [[%{text: "Next", callback_data: "next:2"}]]
           }) == %{"ok" => true}

    assert_receive {:sent, %{inline_keyboard: [[%{callback_data: ref}]]}}

    query = %{
      id: "query-http",
      data: ref,
      from: %{id: 42, is_bot: false, first_name: "Ada"},
      message: %{message_id: 71, chat: %{id: 123}}
    }

    assert :ok = Hub.incoming_callback("bot-token", query)

    response =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get("/api/requests?client_id=default")
      |> json_response(200)

    assert [
             %{
               "datatype" => "callback",
               "callback_query" => %{"id" => "query-http"},
               "req_id" => id,
               "message_thread_id" => 9
             }
           ] = response["requests"]

    assert api(conn, "/api/responses", %{
             req_id: id,
             datatype: "keyboard",
             data: "",
             edit_origin: true,
             inline_keyboard: []
           }) == %{"ok" => true}

    assert_receive {:sent, %{datatype: "keyboard", edit_message_id: 71, inline_keyboard: []}}
  end

  test "long updates return part IDs while final responses retain the original shape", %{
    conn: conn,
    request: request
  } do
    text = String.duplicate("x", 4096) <> "tail"

    assert api(conn, "/api/responses", %{
             req_id: request.req_id,
             datatype: "text",
             data: Base.encode64(text),
             final: false
           }) == %{"ok" => true, "final" => false, "message_id" => 71, "message_ids" => [71, 72]}

    assert_receive {:sent, %{edit_message_id: nil}}
    assert_receive {:sent, %{edit_message_id: nil, data: "tail"}}

    assert api(conn, "/api/responses", %{
             req_id: request.req_id,
             datatype: "text",
             data: Base.encode64("short")
           }) == %{"ok" => true}

    assert_receive {:sent, %{edit_message_id: 71, datatype: "text"}}
    assert_receive {:sent, %{edit_message_id: 72, datatype: "delete"}}
  end

  defp api(conn, path, params) do
    conn
    |> put_req_header("authorization", "Bearer ai-token")
    |> post(path, params)
    |> json_response(200)
  end
end
