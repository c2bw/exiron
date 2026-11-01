defmodule ExironClient.RequestCancellationTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Error, Message, MessageHandler}
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "cancellation helper uses the shared payload and returns the delivery snapshot" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn req ->
            assert req.url.path == "/api/cancellations"
            send(parent, Jason.decode!(req.body))
            {req, Req.Response.json(contract_json("cancel_response.json"))}
          end
        ]
      )

    assert {:ok, result} = ExironClient.cancel_request(client, %Message{req_id: "request-1"})
    assert result == contract_json("cancel_response.json")
    expected = contract_json("cancel_payload.json")
    assert_receive ^expected
  end

  test "a cancelled stream stops on its first error without sending a final update" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn req ->
            send(parent, {:request, Jason.decode!(req.body)})
            {req, %Req.Response{status: 409, body: contract_json("cancelled_error.json")}}
          end
        ]
      )

    assert {:error, %Error{reason: :request_cancelled} = error} =
             ExironClient.stream_text(client, "request", ["first", "later"])

    assert Error.request_cancelled?(error)
    assert_receive {:request, %{"final" => false}}
    refute_receive {:request, _}
  end

  test "managed handlers acknowledge cancellation once and continue with other requests" do
    parent = self()
    error = Error.from_response(409, contract_json("cancelled_error.json"))

    handler = fn message ->
      send(parent, {:handled, message.req_id})
      if message.req_id == "cancelled", do: {:error, error}, else: :ok
    end

    assert :ok =
             MessageHandler.handle(
               [%Message{req_id: "cancelled"}, %Message{req_id: "next"}],
               handler,
               max_attempts: 10,
               wait: fn _ -> flunk("cancelled work was retried") end
             )

    assert_receive {:handled, "cancelled"}
    assert_receive {:handled, "next"}
    refute_receive {:handled, _}
  end
end
