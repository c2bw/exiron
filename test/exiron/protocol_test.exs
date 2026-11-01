defmodule Exiron.ProtocolTest do
  use ExUnit.Case, async: true

  alias Exiron.Protocol

  test "exposes manifest protocol metadata" do
    assert Protocol.protocol_version() == "1.19"
    assert "websocket" in Protocol.capabilities()
    assert "followup_context" in Protocol.capabilities()

    assert Protocol.datatypes() == [
             "text",
             "audio",
             "video",
             "image",
             "file",
             "sticker",
             "album",
             "callback",
             "keyboard"
           ]

    assert Protocol.websocket_server_frame_types() == ["connected", "messages", "pong", "error"]
    assert Protocol.websocket_client_frame_types() == ["ping", "ack"]
  end

  test "builds stable error payloads from the manifest" do
    assert Protocol.error_descriptor(:rate_limited) == %{
             code: "rate_limited",
             status: 429,
             message: "too many requests"
           }

    assert Protocol.error_payload(:unknown) == %{
             code: "internal_error",
             error: "internal error"
           }
  end

  test "adds protocol metadata to auth and WebSocket connected payloads" do
    auth =
      Protocol.auth_payload(%{auth_response: "OK", hook: "assistant", server_version: "0.1.0"})

    assert auth.protocol_version == Protocol.protocol_version()
    assert auth.capabilities == Protocol.capabilities()
    assert auth.msgtype == "auth"

    connected =
      Protocol.connected_payload(%{
        hook: "assistant",
        client_id: "runner",
        listen: false,
        server_version: "0.1.0"
      })

    assert connected.type == "connected"
    assert connected.protocol_version == Protocol.protocol_version()
    assert connected.capabilities == Protocol.capabilities()
  end
end
