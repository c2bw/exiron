defmodule ExironClient.DeliveryDiagnosticsTest do
  use ExUnit.Case, async: true
  alias ExironClient.Error
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "delivery errors retain the shared structured snapshot without changing legacy error codes" do
    error = Error.from_response(504, contract_json("delivery_error.json"))
    assert error.reason == :telegram_delivery_timeout
    assert error.delivery == contract_json("delivery_diagnostics.json")
    assert error.delivery["confirmed_parts"] == 1
    assert error.delivery["last_error"]["retry_after_ms"] == 2000
    refute error.delivery["retry_safe"]
    assert error.delivery["retry_action"] == "inspect_chat"

    assert Error.from_response(400, %{"error" => "invalid payload", "code" => "invalid_payload"}).delivery ==
             nil
  end

  test "delivery status helper fetches a snapshot with bearer authentication" do
    expected = contract_json("delivery_diagnostics.json")

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn req ->
            assert req.url.path == "/api/deliveries/request-1"
            assert Req.Request.get_header(req, "authorization") == ["Bearer token"]
            {req, Req.Response.json(expected)}
          end
        ]
      )

    assert {:ok, ^expected} = ExironClient.delivery_status(client, "request-1")
  end
end
