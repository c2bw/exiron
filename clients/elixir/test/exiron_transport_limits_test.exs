defmodule ExironClient.TransportLimitsTest do
  use ExUnit.Case, async: true

  alias ExironClient.{Error, SocketPoller, SocketTransport}
  alias ExironClient.FixtureHelpers

  test "validates the configured response size limit" do
    assert ExironClient.new(base_url: "http://exiron.test").max_response_bytes ==
             128 * 1024 * 1024

    assert ExironClient.new(base_url: "http://exiron.test", max_response_bytes: 64).max_response_bytes ==
             64

    assert_raise ArgumentError, "max_response_bytes must be a positive integer", fn ->
      ExironClient.new(base_url: "http://exiron.test", max_response_bytes: 0)
    end
  end

  test "limits streamed HTTP response bodies" do
    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        max_response_bytes: 16,
        req_options: [
          adapter: fn request ->
            response = Req.Response.new(status: 200)

            {:halt, {request, response}} =
              request.into.(
                {:data, String.duplicate("x", 17)},
                {request, response}
              )

            {request, response}
          end
        ]
      )

    assert {:error,
            %Error{
              reason: :invalid_response,
              body: %{max_response_bytes: 16}
            }} = ExironClient.status(client)
  end

  test "decodes streamed HTTP response bodies within the limit" do
    body = Jason.encode!(%{enabled: true})

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        max_response_bytes: byte_size(body),
        req_options: [
          adapter: fn request ->
            response = Req.Response.new(status: 200)
            {:cont, {request, response}} = request.into.({:data, body}, {request, response})
            {request, response}
          end
        ]
      )

    assert {:ok, %{"enabled" => true}} = ExironClient.status(client)
  end

  test "websocket transport reads declared frame sizes from headers alone" do
    assert {:ok, %{opcode: :text, payload_size: 17}} =
             SocketTransport.frame_header(<<1::1, 0::3, 1::4, 0::1, 17::7>>)

    assert {:ok, %{opcode: :binary, payload_size: 65_535}} =
             SocketTransport.frame_header(<<1::1, 0::3, 2::4, 0::1, 126::7, 65_535::16>>)

    assert {:ok, %{opcode: :continuation, payload_size: 4_294_967_296}} =
             SocketTransport.frame_header(<<1::1, 0::3, 0::4, 0::1, 127::7, 4_294_967_296::64>>)
  end

  test "websocket poller rejects frames over the configured response limit" do
    parent = self()

    client = FixtureHelpers.socket_client() |> Map.put(:max_response_bytes, 16)

    state =
      FixtureHelpers.socket_state(parent,
        client: client,
        handler: fn _message -> :ok end
      )

    assert %Error{
             reason: :invalid_response,
             body: %{frame_bytes: 17, max_response_bytes: 16}
           } = catch_exit(SocketPoller.handle_frame({:text, String.duplicate("x", 17)}, state))

    assert_receive {:disconnected, %Error{reason: :invalid_response}}
  end

  @tag capture_log: true
  test "websocket transport rejects an oversized frame from its header before payload arrives" do
    port = FixtureHelpers.oversized_frame_server!(self(), 65_535)

    client =
      ExironClient.new(
        base_url: "http://127.0.0.1:#{port}",
        token: "ai-token",
        client_id: "poller",
        max_response_bytes: 16
      )

    poller =
      start_supervised!(
        {ExironClient.Poller,
         runtime_reporting: false, client: client, handler: fn _message -> :ok end},
        restart: :temporary
      )

    poller_ref = Process.monitor(poller)
    assert_receive {:websocket_handshake_complete, server}
    send(server, :send_oversized_header)

    assert_receive {:oversized_header_sent, 65_535}

    assert_receive {:DOWN, ^poller_ref, :process, ^poller,
                    %Error{
                      reason: :invalid_response,
                      body: %{frame_bytes: 65_535, max_response_bytes: 16}
                    }}
  end
end
