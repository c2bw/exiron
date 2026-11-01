defmodule ExironClient.RequestObserverTest do
  use ExUnit.Case, async: true
  alias ExironClient.Request

  test "one sanitized logical completion includes safe retries and isolates callback errors" do
    parent = self()
    calls = start_supervised!({Agent, fn -> 0 end})

    client =
      ExironClient.new(
        base_url: "http://example.test",
        token: "private-token",
        on_request: fn event ->
          send(parent, {:event, event})
          raise "observer error"
        end,
        reconnect_backoff: [
          initial_delay_ms: 1,
          max_delay_ms: 1,
          max_retry_time_ms: 1000,
          jitter: false
        ],
        req_options: [
          adapter: fn req ->
            attempt = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

            if attempt == 1,
              do: {req, %Req.TransportError{reason: :closed}},
              else: {req, Req.Response.json(%{ok: true})}
          end
        ]
      )

    assert {:ok, _} = Request.request(client, :get, "/api/request-state?req_id=private-id")
    assert_receive {:event, event}
    assert event.attempts == 2
    assert event.http_status == 200
    assert event.route == "/api/request-state"
    assert event.error_kind == :none
    refute inspect(event) =~ "private"
    refute_received {:event, _}
  end

  test "mutations are observed once without retrying and unknown routes are redacted" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://example.test",
        on_request: &send(parent, {:event, &1}),
        req_options: [
          adapter: fn req ->
            {req, %Req.Response{status: 504, body: %{"error" => "private body"}}}
          end
        ]
      )

    assert {:error, _} = Request.request(client, :post, "/private-id?token=secret")
    assert_receive {:event, %{attempts: 1, route: "other", http_status: 504}}
    refute_received {:event, _}
  end

  test "delivery diagnostic routes omit their identifiers" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://example.test",
        on_request: &send(parent, {:event, &1}),
        req_options: [adapter: fn req -> {req, Req.Response.json(%{})} end]
      )

    assert {:ok, _} = Request.request(client, :get, "/api/deliveries/private-id?token=secret")
    assert_receive {:event, %{route: "/api/deliveries/:id"} = event}
    refute inspect(event) =~ "private-id"
    refute inspect(event) =~ "secret"
  end

  test "callback configuration is validated before requests" do
    assert_raise ArgumentError, fn ->
      ExironClient.new(base_url: "http://example.test", on_request: :invalid)
    end
  end
end
