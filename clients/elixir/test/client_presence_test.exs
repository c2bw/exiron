defmodule ExironClient.ClientPresenceTest do
  use ExUnit.Case, async: true
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "status preserves optional client presence fields from the shared contract" do
    body = contract_json("status_client_presence_response.json")

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [adapter: fn req -> {req, Req.Response.json(body)} end]
      )

    assert {:ok, %{"hooks" => [%{"client" => presence}]}} = ExironClient.status(client)
    assert presence == hd(body["hooks"])["client"]
    assert presence["state"] == "http_lease_expired"
    assert presence["awaiting_response"] == 1
    assert presence["runtime"]["overdue_handlers"] == 1
    assert presence["runtime"]["status"] == "session_inactive"
    assert presence["runtime"]["stale"]
    assert is_nil(presence["current_client_id"])
  end
end
