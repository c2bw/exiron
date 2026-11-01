defmodule ExironClient.EndpointTest do
  use ExUnit.Case, async: true

  alias ExironClient.Endpoint
  import ExironClient.FixtureHelpers

  setup do
    requests = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "endpoint-test",
        req_options: [adapter: adapter(requests)]
      )

    %{client: client, requests: requests}
  end

  test "facade endpoint calls are equivalent to focused endpoint calls", %{
    client: client
  } do
    assert ExironClient.auth(client) == Endpoint.auth(client, nil)
    assert ExironClient.requests(client) == Endpoint.requests(client, [])
    assert ExironClient.requests_delivery(client) == Endpoint.requests_delivery(client, nil, [])

    assert ExironClient.respond(client, "req-1", "text", "ack") ==
             Endpoint.respond(client, "req-1", "text", "ack", [])

    assert ExironClient.push(client, "text", "hello") ==
             Endpoint.push(client, "text", "hello", [])

    assert ExironClient.push(client, 123, "text", "hello") ==
             Endpoint.push(client, 123, "text", "hello", [])

    assert ExironClient.status(client) == Endpoint.status(client)
  end

  test "focused endpoint construction preserves authenticated request options", %{
    client: client,
    requests: requests
  } do
    assert {:ok, _response} = Endpoint.push(client, "text", "hello", bot: "second-bot")

    [request] = recorded_requests(requests)
    assert request.method == :post
    assert URI.to_string(request.url) == "http://exiron.test/api/push"
    assert has_authorization?(request, "Bearer ai-token")
    assert Jason.decode!(request.body) == contract_json("push_bot_payload.json")
  end
end
