defmodule ExironWeb.ExironControllerContractTest do
  use ExironWeb.ConnCase, async: false

  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}
  import Exiron.Support.RouterHelper

  setup do
    router = load_router!()
    :ok = Hub.configure(router, Telegram.new([]))
    :ok
  end

  test "requires dashboard authentication for the OpenAPI document", %{conn: conn} do
    conn = get(conn, ~p"/api/openapi")

    assert redirected_to(conn) == ~p"/login"
  end

  test "serves the OpenAPI document for authenticated dashboard sessions", %{conn: conn} do
    conn =
      conn
      |> log_in()
      |> recycle()
      |> get(~p"/api/openapi")

    assert %{
             "openapi" => "3.0.0",
             "info" => %{"title" => "Exiron API"},
             "paths" => paths,
             "components" => %{
               "schemas" => schemas,
               "securitySchemes" => security_schemes
             }
           } = json_response(conn, 200)

    assert Map.has_key?(paths, "/api/status")
    assert Map.has_key?(paths, "/api/push")

    assert get_in(paths, ["/api/auth", "post", "security"]) == [
             %{},
             %{"bearerAuth" => []}
           ]

    assert get_in(paths, ["/api/status", "get", "security"]) == [
             %{"bearerAuth" => []}
           ]

    assert get_in(paths, ["/api/event-media/{id}", "get", "security"]) == [
             %{"dashboardSession" => []},
             %{"bearerAuth" => []}
           ]

    assert security_schemes["dashboardSession"] == %{
             "in" => "cookie",
             "name" => "_exiron_key",
             "type" => "apiKey"
           }

    assert get_in(paths, ["/api/auth", "post", "operationId"]) ==
             "ExironWeb.ExironController.auth"

    assert get_in(paths, ["/api/status", "get", "operationId"]) ==
             "ExironWeb.ExironController.status"

    assert get_in(paths, ["/api/requests", "get", "operationId"]) ==
             "ExironWeb.ExironController.requests"

    assert get_in(paths, ["/api/responses", "post", "operationId"]) ==
             "ExironWeb.ExironController.responses"

    assert get_in(paths, ["/api/push", "post", "operationId"]) ==
             "ExironWeb.ExironController.push"

    assert get_in(schemas, ["ClientRequest", "properties", "file_unique_id", "type"]) == "string"
    assert get_in(schemas, ["ClientRequest", "properties", "file_unique_id", "nullable"])
    refute "file_unique_id" in schemas["ClientRequest"]["required"]

    response_payload_properties =
      schemas |> Map.fetch!("ResponsePayload") |> Map.fetch!("properties")

    assert Map.keys(response_payload_properties) |> Enum.sort() ==
             ~w(caption caption_entities caption_overflow data datatype delivery_receipts edit_origin entities file_name final inline_keyboard media_group_id message_thread_id mime_type parse_mode reply_to_original req_id sticker_emoji)

    assert documented_response_codes(paths, "/api/requests", "get") == [
             "200",
             "400",
             "401",
             "409",
             "429",
             "503"
           ]

    assert documented_response_codes(paths, "/api/responses", "post") == [
             "200",
             "400",
             "401",
             "404",
             "409",
             "429",
             "500",
             "503",
             "504"
           ]

    assert documented_response_codes(paths, "/api/push", "post") == [
             "200",
             "400",
             "401",
             "429",
             "500",
             "503",
             "504"
           ]

    assert documented_response_codes(paths, "/api/socket", "get") == [
             "101",
             "401",
             "429",
             "503"
           ]
  end

  test "documents observed controller error responses", %{conn: conn} do
    paths = openapi_paths(conn)

    for {method, path, expected_status, request_fun} <- documented_error_cases() do
      reset_ets_table(:rate_limit_entries)
      :ok = Hub.configure(load_router!(), Telegram.new([]))

      conn =
        conn
        |> recycle()
        |> request_fun.()

      assert %{"error" => _message} = json_response(conn, expected_status)
      assert_response_documented!(paths, path, method, conn.status)
    end
  end

  test "rate limits authentication attempts", %{conn: conn} do
    conn =
      Enum.reduce(1..10, conn, fn _attempt, conn ->
        conn
        |> recycle()
        |> post(~p"/api/auth", %{hook_token: "nope"})
      end)

    assert %{"error" => "invalid token"} = json_response(conn, 401)

    conn =
      conn
      |> recycle()
      |> post(~p"/api/auth", %{hook_token: "nope"})

    assert %{"error" => "too many requests"} = json_response(conn, 429)
    assert get_resp_header(conn, "retry-after") != []
  end

  test "API traffic does not consume the authentication rate limit", %{conn: conn} do
    conn =
      Enum.reduce(1..10, conn, fn _request, conn ->
        conn =
          conn
          |> recycle()
          |> put_req_header("authorization", "Bearer ai-token")
          |> get(~p"/api/status")

        assert json_response(conn, 200)["enabled"]
        conn
      end)

    conn =
      conn
      |> recycle()
      |> post(~p"/api/auth", %{hook_token: "nope"})

    assert %{"error" => "invalid token"} = json_response(conn, 401)
  end

  test "rate limits each bearer token with a high traffic ceiling", %{conn: conn} do
    conn =
      Enum.reduce(1..1200, conn, fn _attempt, conn ->
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer ai-token")
        |> get(~p"/api/status")
      end)

    assert %{"enabled" => true} = json_response(conn, 200)

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/status")

    assert %{"error" => "too many requests"} = json_response(conn, 429)
    assert get_resp_header(conn, "retry-after") != []
  end

  defp load_router! do
    load_router!("controller", """
    aliases:
      telegram:
        home: 123
    routes:
      home:
        middleware:
          - family
        push: true
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "ai-token"
    """)
  end

  defp load_multi_chat_router! do
    load_router!("controller-multi-chat", """
    aliases:
      telegram:
        home: 123
        work: 456
    routes:
      home:
        middleware:
          - family
        push: true
      work:
        middleware:
          - family
        push: true
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "ai-token"
    """)
  end

  defp documented_response_codes(paths, path, method) do
    paths
    |> get_in([path, method, "responses"])
    |> Map.keys()
    |> Enum.sort()
  end

  defp openapi_paths(conn) do
    conn
    |> log_in()
    |> recycle()
    |> get(~p"/api/openapi")
    |> json_response(200)
    |> Map.fetch!("paths")
  end

  defp assert_response_documented!(paths, path, method, status) do
    responses = get_in(paths, [path, Atom.to_string(method), "responses"]) || %{}

    assert Map.has_key?(responses, Integer.to_string(status)),
           "#{method |> Atom.to_string() |> String.upcase()} #{path} returned #{status}, but OpenAPI documents #{inspect(Map.keys(responses) |> Enum.sort())}"
  end

  defp documented_error_cases do
    [
      {:get, "/api/status", 401, fn conn -> get(conn, ~p"/api/status") end},
      {:post, "/api/auth", 401, fn conn -> post(conn, ~p"/api/auth", %{hook_token: "nope"}) end},
      {:get, "/api/socket", 401, fn conn -> get(conn, ~p"/api/socket?client_id=client") end},
      {:get, "/api/requests", 400,
       fn conn ->
         conn
         |> put_req_header("authorization", "Bearer ai-token")
         |> get(~p"/api/requests")
       end},
      {:get, "/api/requests", 409,
       fn conn ->
         assert {:ok, []} = Hub.poll("ai-token", client_id: "active-client")

         conn
         |> put_req_header("authorization", "Bearer ai-token")
         |> get(~p"/api/requests?client_id=other-client")
       end},
      {:post, "/api/responses", 400,
       fn conn ->
         conn
         |> put_req_header("authorization", "Bearer ai-token")
         |> post(~p"/api/responses", %{datatype: "text", data: "not base64"})
       end},
      {:post, "/api/responses", 404,
       fn conn ->
         conn
         |> put_req_header("authorization", "Bearer ai-token")
         |> post(~p"/api/responses", %{
           req_id: "missing",
           datatype: "text",
           data: Base.encode64("hello")
         })
       end},
      {:post, "/api/responses", 409, &request_not_assigned_response/1},
      {:post, "/api/push", 400,
       fn conn ->
         :ok = Hub.configure(load_multi_chat_router!(), Telegram.new([]))

         conn
         |> put_req_header("authorization", "Bearer ai-token")
         |> post(~p"/api/push", %{
           datatype: "text",
           data: Base.encode64("hello"),
           chat_id: 999
         })
       end},
      {:post, "/api/push", 500,
       fn conn ->
         telegram =
           Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
             sender: fn _, _ -> {:error, {:bad_status, 500}} end
           )

         :ok = Hub.configure(load_router!(), telegram)

         conn
         |> put_req_header("authorization", "Bearer ai-token")
         |> post(~p"/api/push", %{datatype: "text", data: Base.encode64("hello")})
       end},
      {:post, "/api/push", 503,
       fn conn ->
         :ok =
           Hub.configure(
             load_router!(),
             Telegram.new([
               %{chat_id: 123, bot_token: "first-token", bot_name: "first-bot"}
             ])
           )

         conn
         |> put_req_header("authorization", "Bearer ai-token")
         |> post(~p"/api/push", %{
           datatype: "text",
           data: Base.encode64("hello"),
           bot: "second-bot"
         })
       end}
    ]
  end

  defp request_not_assigned_response(conn) do
    :ok =
      Hub.configure(
        load_router!("controller-two-hooks", """
        aliases:
          telegram:
            home: 123
        routes:
          home:
            middleware:
              - family
        middlewares:
          family:
            routes:
              status:
                messages:
                  - "/status"
        hooks:
          assistant: "ai-token"
          status: "status-token"
        """),
        Telegram.new([])
      )

    assert {:ok, []} = Hub.poll("status-token", client_id: "status-client")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/status", "bot-token"))
    assert {:ok, [%{req_id: request_id}]} = Hub.poll("status-token", client_id: "status-client")

    conn
    |> put_req_header("authorization", "Bearer ai-token")
    |> post(~p"/api/responses", %{
      req_id: request_id,
      datatype: "text",
      data: Base.encode64("hello")
    })
  end
end
