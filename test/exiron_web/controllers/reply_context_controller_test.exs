defmodule ExironWeb.ReplyContextControllerTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    parent = self()

    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, message ->
            send(parent, {:sent, message})
            {:ok, %{message_id: 901}}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request",
          bot_token: "bot-token",
          message_id: 321,
          reply_to_message_id: 42,
          message_thread_id: 7
        )
      )

    {:ok, [request]} = Hub.poll("ai-token")
    %{request: request}
  end

  test "reply context uses server-owned message, chat and topic IDs", %{conn: conn, request: req} do
    response =
      conn
      |> auth()
      |> post("/api/responses", %{
        req_id: req.req_id,
        datatype: "text",
        data: Base.encode64("reply"),
        reply_to_original: true,
        reply_to_message_id: 999,
        reply_parameters: %{message_id: 999, chat_id: 456},
        chat_id: 456,
        message_thread_id: 555
      })
      |> json_response(200)

    assert response == %{"ok" => true}
    assert_receive {:sent, %{reply_to_message_id: 321, chat_id: 123, message_thread_id: 7}}
  end

  test "invalid flags and push context are rejected without consuming the request", %{
    conn: conn,
    request: req
  } do
    response =
      conn
      |> auth()
      |> post("/api/responses", %{
        req_id: req.req_id,
        datatype: "text",
        data: Base.encode64("reply"),
        reply_to_original: "true"
      })
      |> json_response(400)

    assert response["code"] == "invalid_payload"

    response =
      conn
      |> auth()
      |> post("/api/push", %{
        datatype: "text",
        data: Base.encode64("push"),
        chat_id: 123,
        reply_to_original: true
      })
      |> json_response(400)

    assert response["code"] == "invalid_payload"

    assert conn
           |> auth()
           |> post("/api/responses", %{
             req_id: req.req_id,
             datatype: "text",
             data: Base.encode64("default")
           })
           |> json_response(200) == %{"ok" => true}

    assert_receive {:sent, %{reply_to_message_id: nil}}
  end

  test "caption overflow is decoded for responses and pushes", %{conn: conn, request: req} do
    payload = %{
      datatype: "file",
      data: Base.encode64("bytes"),
      caption: String.duplicate("x", 1025),
      caption_overflow: true
    }

    assert conn
           |> auth()
           |> post("/api/responses", Map.put(payload, :req_id, req.req_id))
           |> json_response(200) == %{"ok" => true}

    assert_receive {:sent, %{datatype: "file", caption: caption}}
    assert String.length(caption) == 1024
    assert_receive {:sent, %{datatype: "text", data: "x", reply_to_message_id: 901}}

    assert conn
           |> auth()
           |> post("/api/push", Map.put(payload, :chat_id, 123))
           |> json_response(200) == %{"ok" => true, "sent" => 1}

    assert_receive {:sent, %{datatype: "file"}}
    assert_receive {:sent, %{datatype: "text"}}
  end

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer ai-token")
end
