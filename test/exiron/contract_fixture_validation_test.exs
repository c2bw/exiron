defmodule Exiron.ContractFixtureValidationTest do
  use ExUnit.Case, async: true

  alias Exiron.ContractFixtureValidation
  alias ExironWeb.ClientSocket

  test "HTTP fixtures validate against OpenAPI schema contracts" do
    for {fixture, schema, direction} <- ContractFixtureValidation.http_fixture_matrix() do
      assert ContractFixtureValidation.validate_http_fixture(fixture, schema, direction)
    end
  end

  describe "websocket fixtures" do
    test "match frames emitted by the server socket" do
      connected = %{
        hook: "assistant",
        client_id: "runner",
        runtime_ref: "runtime-session-1",
        listen: false,
        server_version: Exiron.Hub.server_version(),
        protocol_version: Exiron.Protocol.protocol_version(),
        capabilities: Exiron.Protocol.capabilities(),
        delivery_ref: "delivery-example",
        messages: [
          %{msgtype: "request", req_id: "req-1", datatype: "text", data: "aGVsbG8="}
        ]
      }

      assert [connected_frame, messages_frame] = ClientSocket.connected_frames(connected)

      assert decoded_frame(connected_frame) == fixture("websocket_connected_frame.json")
      assert decoded_frame(messages_frame) == fixture("websocket_messages_frame.json")
      assert decoded_frame(ClientSocket.pong_frame()) == fixture("websocket_pong_frame.json")

      assert decoded_frame(ClientSocket.error_frame({:hook_already_connected, 12})) ==
               fixture("websocket_error_frame.json")
    end

    test "the server accepts the acknowledgement fixture" do
      acknowledgement =
        "websocket_ack_frame.json"
        |> fixture()
        |> Jason.encode!()

      state = %{hook: "assistant", client_id: "runner", delivery_ref: "delivery-example"}

      assert {:ok, %{delivery_ref: nil}} =
               ClientSocket.handle_in({acknowledgement, [opcode: :text]}, state)
    end
  end

  defp fixture(name), do: ContractFixtureValidation.fixture_payload(name)

  defp decoded_frame({:text, payload}), do: Jason.decode!(payload)
end
