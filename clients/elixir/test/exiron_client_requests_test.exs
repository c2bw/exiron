defmodule ExironClientRequestsTest do
  use ExUnit.Case, async: true

  alias ExironClient.{Message, SocketPoller, SocketWorker}
  import ExironClient.FixtureHelpers

  setup do
    requests = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "test-client",
        req_options: [adapter: adapter(requests)]
      )

    %{client: client, requests: requests}
  end

  test "OTP status callbacks redact client tokens and handled messages", %{client: client} do
    message_secret = "message-secret-a8eb83d1"
    reason_secret = "reason-secret-d3cb34cc"
    log_secret = "log-secret-09cfc8c7"

    http_state = %{
      client: client,
      handler: fn _message -> :ok end,
      interval_ms: 1_000,
      disconnect_timeout_ms: 2_000,
      on_connect: fn -> :ok end,
      on_disconnect: fn _reason -> :ok end,
      connected?: true
    }

    http_status =
      ExironClient.Poller.format_status(%{
        state: http_state,
        message: {:"$gen_call", {self(), make_ref()}, {:enqueue, message_secret}},
        reason: %RuntimeError{message: reason_secret},
        log: [{:in, log_secret}]
      })

    assert http_status.state.client == %{
             base_url: "http://exiron.test",
             client_id: "test-client",
             listen?: false
           }

    assert http_status.message == {:call, :enqueue}
    assert http_status.reason == {:exception, RuntimeError}
    assert http_status.log == []

    websocket_state = socket_state(self(), handler: fn _message -> :ok end, client: client)

    assert [data: [{~c"State", websocket_status}]] =
             SocketPoller.format_status(:terminate, [[], websocket_state])

    assert websocket_status.client == http_status.state.client

    worker_state = %{
      owner: self(),
      owner_ref: make_ref(),
      handler: fn _message -> :ok end,
      pending: {make_ref(), [message_secret]},
      status: {:failed, {:handler_failed, reason_secret}}
    }

    worker_status =
      SocketWorker.format_status(%{
        state: worker_state,
        message: {:"$gen_call", {self(), make_ref()}, {:enqueue, [message_secret]}},
        reason: {:handler_failed, reason_secret},
        log: [{:in, log_secret}]
      })

    assert worker_status.state == %{owner: self(), pending?: true, status: :failed}
    assert worker_status.message == {:call, :enqueue}
    assert worker_status.reason == :handler_failed
    assert worker_status.log == []

    report = inspect({client, http_status, websocket_status, worker_status})
    refute report =~ "ai-token"
    refute report =~ message_secret
    refute report =~ reason_secret
    refute report =~ log_secret
  end

  test "authenticates with the configured token", %{client: client, requests: requests} do
    assert {:ok, %ExironClient.Auth{auth_response: "OK", hook: "assistant", msgtype: "auth"}} =
             ExironClient.auth(client)

    [request] = recorded_requests(requests)
    assert request.method == :post
    assert URI.to_string(request.url) == "http://exiron.test/api/auth"
    assert Jason.decode!(request.body) == %{"hook_token" => "ai-token"}
    assert has_authorization?(request, "Bearer ai-token")
  end

  test "authenticates an override token consistently", %{client: client, requests: requests} do
    assert {:ok, %ExironClient.Auth{auth_response: "OK"}} =
             ExironClient.auth(client, "override-token")

    [request] = recorded_requests(requests)
    assert Jason.decode!(request.body) == %{"hook_token" => "override-token"}
    assert has_authorization?(request, "Bearer override-token")
    refute has_authorization?(request, "Bearer ai-token")
  end

  test "decodes the shared auth response contract fixture", %{client: client} do
    client =
      put_in(client.req_options[:adapter], fn request ->
        body = File.read!(Path.expand("../../contract/auth_response.json", __DIR__))
        {request, Req.Response.new(status: 200, body: Jason.decode!(body))}
      end)

    assert {:ok,
            %ExironClient.Auth{
              auth_response: "OK",
              hook: "assistant",
              msgtype: "auth",
              server_version: "0.1.0"
            } = auth} = ExironClient.auth(client)

    protocol = ExironClient.Auth.protocol(auth)
    assert protocol.version == ExironClient.Protocol.Generated.version()
    assert ExironClient.Protocol.supports?(protocol, "http_delivery_ack")
  end

  test "fetches and decodes queued requests", %{client: client, requests: requests} do
    assert {:ok, [%Message{} = message]} = ExironClient.requests(client)

    assert message.msgtype == "request"
    assert message.req_id == "req-1"
    assert message.message_id == 789
    assert message.reply_to_message_id == 456

    assert message.from == %{
             "id" => 42,
             "is_bot" => false,
             "first_name" => "Ada",
             "last_name" => "Lovelace",
             "username" => "ada",
             "language_code" => "en"
           }

    assert message.service_id == 222
    assert message.chat_id == 123
    assert message.instance == "assistant-bot"
    assert message.datatype == "text"
    assert message.sticker_id == "sticker-id"
    assert message.file_unique_id == "sticker-unique-id"
    assert message.sticker_emoji == "\u{1F923}"

    assert message.emoji_list == [
             "\u{1F606}",
             "\u{1F923}",
             "\u{1F600}",
             "\u{1F602}",
             "\u{1F604}",
             "\u{1F603}",
             "\u{1F601}"
           ]

    assert message.data == "/ai hello"
    assert Message.text(message) == "/ai hello"

    [request] = recorded_requests(requests)
    assert request.method == :get

    assert URI.to_string(request.url) ==
             "http://exiron.test/api/requests?client_id=test-client&listen=false"

    assert has_authorization?(request, "Bearer ai-token")
  end

  test "request options cannot redirect authenticated calls", %{
    client: client,
    requests: requests
  } do
    assert {:ok, [%Message{}]} =
             ExironClient.requests(client,
               method: :post,
               url: "http://attacker.test/collect"
             )

    [request] = recorded_requests(requests)
    assert request.method == :get

    assert URI.to_string(request.url) ==
             "http://exiron.test/api/requests?client_id=test-client&listen=false"

    assert has_authorization?(request, "Bearer ai-token")
  end

  test "decodes the shared requests response contract fixture", %{client: client} do
    client =
      put_in(client.req_options[:adapter], fn request ->
        body = File.read!(Path.expand("../../contract/requests_response.json", __DIR__))
        {request, Req.Response.new(status: 200, body: Jason.decode!(body))}
      end)

    assert {:ok, [%Message{} = message]} = ExironClient.requests(client)
    assert message.msgtype == "request"
    assert message.req_id == "req-1"
    assert message.data == "/ai hello"
    assert message.sticker_emoji == "\u{1F923}"
    assert length(message.emoji_list) == 7
  end

  test "declares configured listen mode while polling", %{requests: requests} do
    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "listener",
        listen: true,
        req_options: [adapter: adapter(requests)]
      )

    assert {:ok, [%Message{}]} = ExironClient.requests(client)

    assert [poll] = recorded_requests(requests)

    assert URI.to_string(poll.url) ==
             "http://exiron.test/api/requests?client_id=listener&listen=true"
  end

  test "declares listen all mode while polling", %{requests: requests} do
    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "listener",
        listen: :all,
        req_options: [adapter: adapter(requests)]
      )

    assert {:ok, [%Message{}]} = ExironClient.requests(client)

    assert [poll] = recorded_requests(requests)

    assert URI.to_string(poll.url) ==
             "http://exiron.test/api/requests?client_id=listener&listen=all"
  end

  test "accepts nullable Telegram message ids from queued requests", %{client: client} do
    client =
      put_in(client.req_options[:adapter], fn request ->
        response =
          Req.Response.json(%Req.Response{status: 200}, %{
            requests: [
              %{
                msgtype: "listen",
                req_id: "req-2",
                message_id: nil,
                reply_to_message_id: nil,
                from: nil,
                service_id: 222,
                chat_id: 123,
                instance: "assistant-bot",
                datatype: "text",
                data: Base.encode64("hello")
              }
            ]
          })

        {request, response}
      end)

    assert {:ok,
            [
              %Message{
                message_id: nil,
                reply_to_message_id: nil,
                msgtype: "listen"
              }
            ]} = ExironClient.requests(client)
  end

  test "responds to a message with base64 encoded data", %{client: client, requests: requests} do
    message = %Message{req_id: "req-1"}

    assert {:ok, %{"ok" => true}} = ExironClient.reply_text(client, message, "ack")

    [request] = recorded_requests(requests)
    assert request.method == :post
    assert URI.to_string(request.url) == "http://exiron.test/api/responses"

    assert Jason.decode!(request.body) == contract_json("response_payload.json")
  end

  test "pushes base64 encoded data", %{client: client, requests: requests} do
    assert {:ok, %{"ok" => true, "sent" => 2}} = ExironClient.push_text(client, "hello")

    [request] = recorded_requests(requests)
    assert request.method == :post
    assert URI.to_string(request.url) == "http://exiron.test/api/push"

    assert Jason.decode!(request.body) == contract_json("push_payload.json")
  end

  test "pushes with a selected Telegram bot", %{client: client, requests: requests} do
    assert {:ok, %{"ok" => true, "sent" => 2}} =
             ExironClient.push_text(client, "hello", bot: "second-bot")

    [request] = recorded_requests(requests)
    assert request.method == :post
    assert URI.to_string(request.url) == "http://exiron.test/api/push"

    assert Jason.decode!(request.body) == contract_json("push_bot_payload.json")
  end

  test "pushes sticker file ids and emoji as base64 encoded data", %{
    client: client,
    requests: requests
  } do
    assert {:ok, %{"ok" => true, "sent" => 2}} =
             ExironClient.push_sticker(client, "sticker-file-id", "🔥")

    [request] = recorded_requests(requests)
    assert request.method == :post
    assert URI.to_string(request.url) == "http://exiron.test/api/push"

    assert Jason.decode!(request.body) == contract_json("push_sticker_payload.json")
  end

  test "responds with sticker file ids and emoji", %{client: client, requests: requests} do
    assert {:ok, %{"ok" => true}} =
             ExironClient.reply_sticker(client, "req-1", "sticker-file-id", "🔥")

    [request] = recorded_requests(requests)
    assert request.method == :post
    assert URI.to_string(request.url) == "http://exiron.test/api/responses"

    assert Jason.decode!(request.body) == contract_json("response_sticker_payload.json")
  end

  test "pushes base64 encoded data to a specific chat", %{client: client, requests: requests} do
    assert {:ok, %{"ok" => true, "sent" => 2}} =
             ExironClient.push_text(client, -1_001_234_567_890, "hello")

    [request] = recorded_requests(requests)
    assert request.method == :post
    assert URI.to_string(request.url) == "http://exiron.test/api/push"

    assert Jason.decode!(request.body) == contract_json("push_chat_payload.json")
  end

  test "fetches status", %{client: client, requests: requests} do
    assert {:ok, status} = ExironClient.status(client)
    assert status["enabled"] == true
    assert status["version"] == "0.1.0"
    assert [%{"name" => "assistant"}] = status["hooks"]

    [request] = recorded_requests(requests)
    assert request.method == :get
    assert URI.to_string(request.url) == "http://exiron.test/api/status"
  end
end
