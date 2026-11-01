defmodule ExironClient.ClientIdentityTest do
  use ExUnit.Case, async: true

  test "HTTP polls automatically identify the SDK package independently of protocol" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://example.test",
        token: "token",
        client_id: "worker",
        req_options: [
          adapter: fn req ->
            send(
              parent,
              {:identity, Req.Request.get_header(req, "x-exiron-sdk"),
               Req.Request.get_header(req, "x-exiron-sdk-version")}
            )

            {req, Req.Response.json(%{requests: []})}
          end
        ]
      )

    assert {:ok, []} = ExironClient.requests(client)
    version = ExironClient.Version.current()
    assert_receive {:identity, ["elixir"], [^version]}
  end
end
