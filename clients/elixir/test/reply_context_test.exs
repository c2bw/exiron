defmodule ExironClient.ReplyContextTest do
  use ExUnit.Case, async: true
  alias ExironClient.Wire.Payload
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "reply options match the shared contract and defaults omit the flag" do
    assert json(Payload.response("req-1", "text", "ack", reply_to_original: true)) ==
             contract_json("response_reply_context_payload.json")

    assert json(
             Payload.response("req-1", "text", "partial",
               reply_to_original: true,
               final: false,
               parse_mode: "plain"
             )
           ) == contract_json("response_reply_context_update_payload.json")

    refute Map.has_key?(Payload.response("req-1", "text", "ack"), :reply_to_original)
  end

  test "existing response and stream helpers retain opt-in context" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn req ->
            send(parent, {:request, req.url.path, Jason.decode!(req.body)})
            {req, Req.Response.json(%{ok: true})}
          end
        ]
      )

    assert {:ok, _} =
             ExironClient.respond(client, "req-1", "text", "ack", reply_to_original: true)

    expected = contract_json("response_reply_context_payload.json")
    assert_receive {:request, "/api/responses", ^expected}

    assert {:ok, _} =
             ExironClient.stream_text(client, "req-1", ["partial", " result"],
               reply_to_original: true,
               interval_ms: 100_000
             )

    expected = contract_json("response_reply_context_update_payload.json")
    assert_receive {:request, "/api/responses", ^expected}

    assert_receive {:request, "/api/responses",
                    %{"reply_to_original" => true, "final" => true, "data" => final}}

    assert Base.decode64!(final) == "partial result"
    assert {:ok, _} = ExironClient.reply_text(client, "other", "default")
    assert_receive {:request, "/api/responses", body}
    refute Map.has_key?(body, "reply_to_original")
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
