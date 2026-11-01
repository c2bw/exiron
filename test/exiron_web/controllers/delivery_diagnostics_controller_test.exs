defmodule ExironWeb.DeliveryDiagnosticsControllerTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    router = Exiron.HubCase.load_push_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "other", Exiron.Hub.HookToken.hash("other-token"))
    }

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ ->
            {:error, %ExGram.Error{code: 400, message: "secret-body bot-token"}}
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

  test "HTTP error enrichment preserves codes and exposes hook-scoped diagnostics", %{
    conn: conn,
    request: req
  } do
    body =
      api(conn, :post, "/api/responses", %{
        req_id: req.req_id,
        datatype: "text",
        data: Base.encode64("secret-body")
      })
      |> json_response(500)

    assert body["code"] == "internal_error"
    assert body["delivery"]["last_error"]["code"] == 400
    assert body["delivery"]["retry_action"] == "fix_request"
    assert body["delivery"]["retry_safe"]
    refute Jason.encode!(body) =~ "bot-token"
    refute Jason.encode!(body) =~ "secret-body"
    id = body["delivery"]["id"]
    assert api(conn, :get, "/api/deliveries/#{id}", %{}) |> json_response(200) == body["delivery"]

    assert api(conn, :get, "/api/deliveries/#{req.req_id}", %{}) |> json_response(200) ==
             body["delivery"]

    assert conn |> get("/api/deliveries/#{id}") |> json_response(401) |> Map.fetch!("code") ==
             "missing_token"

    assert conn
           |> put_req_header("authorization", "Bearer other-token")
           |> get("/api/deliveries/#{id}")
           |> json_response(409)
           |> Map.fetch!("code") == "request_not_assigned"

    assert api(conn, :get, "/api/deliveries/missing", %{})
           |> json_response(404)
           |> Map.fetch!("code") == "delivery_not_found"
  end

  test "push failures include diagnostics and remain safely identifiable", %{conn: conn} do
    body =
      api(conn, :post, "/api/push", %{
        datatype: "text",
        data: Base.encode64("payload"),
        chat_id: 123
      })
      |> json_response(500)

    assert body["delivery"]["operation"] == "push"
    assert body["delivery"]["request_id"] == nil
    assert body["delivery"]["parts"] |> hd() |> Map.fetch!("chat_id") == 123
    assert body["delivery"]["retry_safe"]
  end

  test "pre-send validation errors retain the original shape", %{conn: conn, request: req} do
    body =
      api(conn, :post, "/api/responses", %{req_id: req.req_id, datatype: "text", data: "%%%"})
      |> json_response(400)

    assert body == %{"code" => "invalid_base64_data", "error" => "invalid base64 data"}

    assert api(conn, :get, "/api/deliveries/#{req.req_id}", %{})
           |> json_response(404)
           |> Map.fetch!("code") == "delivery_not_found"
  end

  defp api(conn, method, path, params),
    do:
      conn |> put_req_header("authorization", "Bearer ai-token") |> send_api(method, path, params)

  defp send_api(conn, :get, path, params), do: get(conn, path, params)
  defp send_api(conn, :post, path, params), do: post(conn, path, params)
end
