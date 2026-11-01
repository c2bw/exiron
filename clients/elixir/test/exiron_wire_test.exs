defmodule ExironClient.WireTest do
  use ExUnit.Case, async: true

  alias ExironClient.Auth, as: PublicAuth
  alias ExironClient.Error, as: PublicError
  alias ExironClient.Message, as: PublicMessage
  alias ExironClient.Wire.Auth, as: WireAuth
  alias ExironClient.Wire.Error, as: WireError
  alias ExironClient.Wire.Message, as: WireMessage
  alias ExironClient.Wire.Payload, as: WirePayload
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "message wire decoding remains equivalent to the public model API" do
    params = contract_json("requests_response.json") |> Map.fetch!("requests") |> hd()

    assert {:ok, public_message} = ExironClient.Message.from_server(params, :request)
    assert {:ok, wire_message} = WireMessage.decode(params, :request)
    assert public_message == wire_message
    assert public_message.req_id == "req-1"
    assert public_message.data == "/ai hello"
  end

  test "wire message errors preserve the public error shape" do
    assert {:error, public_error} = PublicMessage.from_server(%{"data" => "%%%"}, :request)
    assert {:error, wire_error} = WireMessage.decode(%{"data" => "%%%"}, :request)
    assert public_error == wire_error

    assert public_error == %PublicError{
             reason: :invalid_response,
             message: "message data is not valid base64"
           }
  end

  test "auth wire decoding returns a typed response and retains unknown fields" do
    response = Map.put(contract_json("auth_response.json"), "future_field", "future-value")

    assert WireAuth.decode(response) == PublicAuth.from_wire(response)

    assert %PublicAuth{
             auth_response: "OK",
             hook: "assistant",
             protocol_version: "1.19",
             extra: %{"future_field" => "future-value"}
           } = WireAuth.decode(response)

    assert WireAuth.request("ai-token") == %{hook_token: "ai-token"}
  end

  test "wire payload encoders match the shared request fixtures" do
    assert json(WirePayload.response("req-1", "text", "ack")) ==
             contract_json("response_payload.json")

    assert json(WirePayload.push("text", "hello")) ==
             contract_json("push_payload.json")

    assert json(WirePayload.push("text", "hello", bot: "second-bot")) ==
             contract_json("push_bot_payload.json")

    assert json(WirePayload.push("sticker", "sticker-file-id", sticker_emoji: "🔥")) ==
             contract_json("push_sticker_payload.json")

    assert json(WirePayload.response("req-1", "sticker", "sticker-file-id", sticker_emoji: "🔥")) ==
             contract_json("response_sticker_payload.json")
  end

  test "wire error decoding remains equivalent to the public model API" do
    body = contract_json("error_response.json")

    assert WireError.from_response(409, body) == PublicError.from_response(409, body)
    assert WireError.reason_from_message(body["error"]) == :hook_already_connected
  end

  defp json(payload), do: Jason.decode!(Jason.encode!(payload))
end
