defmodule ExironWeb.DeliveryReceiptsTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    ids = start_supervised!({Agent, fn -> 900 end})

    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "secret-bot-token"}],
          sender: fn _, _ ->
            id = Agent.get_and_update(ids, fn n -> {n + 1, n + 1} end)
            {:ok, %{message_id: id}}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    %{ids: ids}
  end

  test "final responses return scoped IDs only when requested, including all split parts", %{
    conn: conn
  } do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai hello",
          bot_token: "secret-bot-token",
          message_id: 10,
          message_thread_id: 7
        )
      )

    {:ok, [request]} = Hub.poll("ai-token")

    result =
      api(conn, "/api/responses", %{
        req_id: request.req_id,
        datatype: "text",
        data: Base.encode64(String.duplicate("a", 9000)),
        delivery_receipts: true
      })

    assert result == %{
             "ok" => true,
             "receipts" => [
               %{
                 "service_id" => 222,
                 "chat_id" => 123,
                 "message_thread_id" => 7,
                 "message_ids" => [901, 902, 903]
               }
             ]
           }

    refute Jason.encode!(result) =~ "secret-bot-token"
  end

  test "push receipts survive idempotent replay without resending", %{conn: conn, ids: ids} do
    payload = %{
      chat_id: 123,
      datatype: "text",
      data: Base.encode64("autonomous"),
      delivery_receipts: true,
      idempotency_key: "receipt-push"
    }

    first = api(conn, "/api/idempotent/push", payload)

    assert first == %{
             "ok" => true,
             "sent" => 1,
             "receipts" => [
               %{
                 "service_id" => 222,
                 "chat_id" => 123,
                 "message_thread_id" => nil,
                 "message_ids" => [901]
               }
             ]
           }

    assert api(conn, "/api/idempotent/push", payload) == first
    assert Agent.get(ids, & &1) == 901
  end

  test "sticker pushes expose the Telegram ID and old clients keep the count response", %{
    conn: conn
  } do
    assert %{"receipts" => [%{"message_ids" => [901]}]} =
             api(conn, "/api/push", %{
               chat_id: 123,
               datatype: "sticker",
               data: Base.encode64("sticker-file"),
               delivery_receipts: true
             })

    assert api(conn, "/api/push", %{
             chat_id: 123,
             datatype: "text",
             data: Base.encode64("old client")
           }) == %{"ok" => true, "sent" => 1}
  end

  test "receipt flags are validated before sending", %{conn: conn, ids: ids} do
    result =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post("/api/push", %{
        chat_id: 123,
        datatype: "text",
        data: Base.encode64("hello"),
        delivery_receipts: "true"
      })
      |> json_response(400)

    assert result["code"] == "invalid_payload"
    assert Agent.get(ids, & &1) == 900
  end

  defp api(conn, path, payload),
    do:
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(path, payload)
      |> json_response(200)
end
