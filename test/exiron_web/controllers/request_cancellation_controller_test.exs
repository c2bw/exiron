defmodule ExironWeb.RequestCancellationControllerTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    parent = self()

    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, message ->
            send(parent, {:sent, message})
            {:ok, %{message_id: message.edit_message_id || 901}}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request", bot_token: "bot-token")
      )

    {:ok, [request]} = Hub.poll("ai-token")
    %{request: request}
  end

  test "cancellations use bearer auth and typed conflict errors", %{conn: conn, request: request} do
    assert conn
           |> post("/api/cancellations", %{req_id: request.req_id})
           |> json_response(401)
           |> Map.fetch!("code") == "missing_token"

    result = api(conn, "/api/cancellations", %{req_id: request.req_id}) |> json_response(200)

    assert result == %{
             "ok" => true,
             "cancelled" => true,
             "delivery_status" => "not_started",
             "message_ids" => []
           }

    assert api(conn, "/api/cancellations", %{req_id: request.req_id}) |> json_response(200) ==
             result

    for path <- ["/api/responses", "/api/actions", "/api/edits"] do
      result =
        api(conn, path, %{
          req_id: request.req_id,
          datatype: "text",
          data: Base.encode64("late"),
          action: "typing"
        })
        |> json_response(409)

      assert result == %{"code" => "request_cancelled", "error" => "request cancelled"}
    end

    refute_receive {:sent, _}
  end

  test "stream cancellation reports delivered IDs and validates request IDs", %{
    conn: conn,
    request: request
  } do
    {:ok, _} = Hub.respond("ai-token", request.req_id, "text", "partial", final: false)
    assert_receive {:sent, _}

    assert api(conn, "/api/cancellations", %{req_id: request.req_id}) |> json_response(200) == %{
             "ok" => true,
             "cancelled" => true,
             "delivery_status" => "partial",
             "message_ids" => [901]
           }

    assert api(conn, "/api/cancellations", %{}) |> json_response(400) |> Map.fetch!("code") ==
             "invalid_payload"

    assert api(conn, "/api/cancellations", %{req_id: "unknown"})
           |> json_response(404)
           |> Map.fetch!("code") == "request_not_found"
  end

  defp api(conn, path, params),
    do: conn |> put_req_header("authorization", "Bearer ai-token") |> post(path, params)
end
