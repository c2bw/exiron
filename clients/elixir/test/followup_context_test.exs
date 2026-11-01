defmodule ExironClient.FollowupContextTest do
  use ExUnit.Case, async: true
  alias ExironClient.Message
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "shared follow-up payload retains request link while older requests remain valid" do
    payload = contract_json("requests_followup_response.json")
    assert {:ok, [message]} = Message.from_server_list(payload["requests"], :request)
    assert message.followup_req_id == "req-parent"
    assert message.req_id == "req-followup"
    assert message.data == "more"

    assert {:ok, [old]} =
             Message.from_server_list(
               contract_json("requests_response.json")["requests"],
               :request
             )

    assert old.followup_req_id == nil
  end
end
