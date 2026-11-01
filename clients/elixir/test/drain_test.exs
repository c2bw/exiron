defmodule ExironClient.DrainTest do
  use ExUnit.Case, async: true

  test "draining rejects new work with a stable reason and no automatic retry" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn request ->
            send(parent, :mutation)

            {request,
             Req.Response.json(%Req.Response{status: 503}, %{
               code: "draining",
               error: "intake paused for drain"
             })}
          end
        ]
      )

    assert {:error, error} = ExironClient.push(client, "text", "new")
    assert error.reason == :draining
    assert ExironClient.Error.draining?(error)
    refute ExironClient.Error.draining?(nil)
    refute ExironClient.Error.send_capacity_exceeded?(error)
    assert_receive :mutation
    refute_receive :mutation
  end
end
