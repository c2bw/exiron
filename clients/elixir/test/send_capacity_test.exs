defmodule ExironClient.SendCapacityTest do
  use ExUnit.Case, async: true
  alias ExironClient.Error
  import ExironClient.FixtureHelpers, only: [contract_json: 1]

  test "status preserves additive per-hook send byte capacity fields" do
    body = %{
      "hooks" => [
        %{
          "name" => "assistant",
          "health" => %{
            "in_flight_send_bytes" => 12,
            "in_flight_send_bytes_limit" => 100,
            "send_byte_capacity_rejections" => 2
          }
        }
      ]
    }

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        req_options: [adapter: fn req -> {req, Req.Response.json(body)} end]
      )

    assert {:ok, %{"hooks" => [%{"health" => health}]}} = ExironClient.status(client)
    assert health["in_flight_send_bytes"] == 12
    assert health["in_flight_send_bytes_limit"] == 100
    assert health["send_byte_capacity_rejections"] == 2
  end

  test "normalizes overload and retry hints without retrying mutation requests" do
    parent = self()
    body = contract_json("error_hook_send_queue_full.json")

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        reconnect: true,
        req_options: [
          adapter: fn req ->
            send(parent, {:attempt, req.url.path})
            {req, %Req.Response{status: 503, body: body, headers: %{"retry-after" => ["1"]}}}
          end
        ]
      )

    assert {:error, %Error{reason: :hook_send_queue_full, retry_after_ms: 1000} = error} =
             ExironClient.reply_text(client, "req-1", "reply")

    assert Error.send_capacity_exceeded?(error)
    assert_receive {:attempt, "/api/responses"}
    refute_receive {:attempt, _}
    assert {:error, error} = ExironClient.push(client, 123, "text", "push")
    assert Error.send_capacity_exceeded?(error)
    assert_receive {:attempt, "/api/push"}
    refute_receive {:attempt, _}

    assert Error.send_capacity_exceeded?(
             Error.from_response(503, %{"code" => "send_queue_full", "error" => "send queue full"})
           )

    refute Error.send_capacity_exceeded?(Error.new(:telegram_delivery_timeout, "unknown"))
    refute Error.send_capacity_exceeded?(nil)
  end

  test "a saturated stream stops on its rejected update without replay or finalization" do
    parent = self()
    body = contract_json("error_hook_send_queue_full.json")

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn req ->
            payload = Jason.decode!(req.body)
            send(parent, {:update, payload})

            if payload["final"] == false,
              do: {req, Req.Response.json(%{ok: true, final: false, message_id: 901})},
              else: {req, %Req.Response{status: 503, body: body}}
          end
        ]
      )

    assert {:error, error} =
             ExironClient.stream_text(client, "req-1", ["partial", " done"], interval_ms: 100_000)

    assert Error.send_capacity_exceeded?(error)
    assert_receive {:update, %{"final" => false}}
    assert_receive {:update, %{"final" => true}}
    refute_receive {:update, _}
  end
end
