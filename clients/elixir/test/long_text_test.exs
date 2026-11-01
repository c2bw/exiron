defmodule ExironClient.LongTextTest do
  use ExUnit.Case, async: true
  alias ExironClient.Error
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "streams cross the old limit and retain multipart receipts and completion semantics" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn req ->
            body = Jason.decode!(req.body)
            send(parent, {:request, body})

            result =
              if body["final"],
                do: %{"ok" => true},
                else: contract_json("long_response_update.json")

            {req, Req.Response.json(result)}
          end
        ]
      )

    fixture = contract_json("long_response_payload.json")
    text = Base.decode64!(fixture["data"])

    assert {:ok, %{"message_ids" => [901, 902]}} =
             ExironClient.update_text(client, "long-request", text)

    assert_receive {:request, ^fixture}

    assert {:ok, %{"ok" => true}} =
             ExironClient.stream_text(client, "request", [String.duplicate("x", 4096), "😀tail"],
               interval_ms: 100_000
             )

    assert_receive {:request, %{"final" => false, "data" => first}}
    assert Base.decode64!(first) == String.duplicate("x", 4096)
    assert_receive {:request, %{"final" => true, "data" => final}}
    assert Base.decode64!(final) == text
    refute_receive {:request, _}
  end

  test "logical stream size and UTF-8 remain bounded before any request" do
    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        req_options: [adapter: fn _ -> flunk("oversized stream was sent") end]
      )

    assert {:error, %Error{reason: :invalid_payload}} =
             ExironClient.stream_text(client, "request", [String.duplicate("x", 131_073)])

    assert {:error, %Error{reason: :invalid_payload}} =
             ExironClient.stream_text(client, "request", [<<255>>])
  end
end
