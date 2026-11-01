defmodule ExironClient.RetryTest do
  use ExUnit.Case, async: true

  alias ExironClient.Error
  import ExironClient.FixtureHelpers

  setup do
    requests = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "test-client",
        req_options: [adapter: adapter(requests)]
      )

    %{client: client, requests: requests}
  end

  test "retries transport errors with exponential reconnect backoff", %{requests: requests} do
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())
    attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        req_options: [
          retry: :transient,
          adapter: fn request ->
            assert request.options.retry == false
            Agent.update(requests, &[request | &1])
            attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

            if attempt < 3 do
              {request, %Req.TransportError{reason: :econnrefused}}
            else
              {request, Req.Response.json(%{enabled: true})}
            end
          end
        ],
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 10,
          max_delay_ms: 30_000,
          max_retry_time_ms: 30_000,
          sleep: fn delay_ms -> Agent.update(sleeps, &[delay_ms | &1]) end
        ]
      )

    assert {:ok, %{"enabled" => true}} = ExironClient.status(client)
    assert length(recorded_requests(requests)) == 3
    assert Agent.get(sleeps, &Enum.reverse/1) == [10, 20]
  end

  test "does not retry pushes after an ambiguous transport error", %{requests: requests} do
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        req_options: [
          retry: :transient,
          adapter: fn request ->
            assert request.options.retry == false
            Agent.update(requests, &[request | &1])
            {request, %Req.TransportError{reason: :closed}}
          end
        ],
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 10,
          max_delay_ms: 30_000,
          max_retry_time_ms: 30_000,
          sleep: fn delay_ms -> Agent.update(sleeps, &[delay_ms | &1]) end
        ]
      )

    assert {:error, %Error{reason: :transport_error}} = ExironClient.push_text(client, "hello")
    assert length(recorded_requests(requests)) == 1
    assert Agent.get(sleeps, &Enum.reverse/1) == []
  end

  test "does not retry one-shot polls after an ambiguous transport error", %{requests: requests} do
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        req_options: [
          adapter: fn request ->
            Agent.update(requests, &[request | &1])
            {request, %Req.TransportError{reason: :closed}}
          end
        ],
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 10,
          max_delay_ms: 30_000,
          max_retry_time_ms: 30_000,
          sleep: fn delay_ms -> Agent.update(sleeps, &[delay_ms | &1]) end
        ]
      )

    assert {:error, %Error{reason: :transport_error}} = ExironClient.requests(client)
    assert length(recorded_requests(requests)) == 1
    assert Agent.get(sleeps, &Enum.reverse/1) == []
  end

  test "stops retrying when the reconnect sleep hook returns an error", %{requests: requests} do
    attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())
    sleep_error = Error.new(:request_error, "retry canceled")

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        req_options: [
          adapter: fn request ->
            Agent.update(requests, &[request | &1])
            Agent.update(attempts, &(&1 + 1))
            {request, %Req.TransportError{reason: :econnrefused}}
          end
        ],
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 10,
          max_delay_ms: 30_000,
          max_retry_time_ms: 30_000,
          sleep: fn 10 -> {:error, sleep_error} end
        ]
      )

    assert {:error, ^sleep_error} = ExironClient.status(client)
    assert Agent.get(attempts, & &1) == 1
  end

  test "retries hook already connected with the server delay", %{requests: requests} do
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())
    attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "worker",
        req_options: [
          adapter: fn request ->
            Agent.update(requests, &[request | &1])
            attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

            if attempt == 1 do
              {request,
               Req.Response.json(%Req.Response{status: 409}, %{
                 error: "hook already connected",
                 retry_after_ms: 12
               })}
            else
              {request, Req.Response.json(%{"requests" => []})}
            end
          end
        ],
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 250,
          max_delay_ms: 30_000,
          max_retry_time_ms: 30_000,
          sleep: fn delay_ms -> Agent.update(sleeps, &[delay_ms | &1]) end
        ]
      )

    assert {:ok, %{messages: []}} = ExironClient.requests_delivery(client)
    assert length(recorded_requests(requests)) == 2
    assert Agent.get(sleeps, &Enum.reverse/1) == [12]
  end

  test "stops reconnecting after the configured retry time", %{requests: requests} do
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        req_options: [
          adapter: fn request ->
            Agent.update(requests, &[request | &1])
            {request, %Req.TransportError{reason: :econnrefused}}
          end
        ],
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 20,
          max_delay_ms: 30_000,
          max_retry_time_ms: 19,
          sleep: fn delay_ms -> Agent.update(sleeps, &[delay_ms | &1]) end
        ]
      )

    assert {:error, %Error{reason: :transport_error}} = ExironClient.status(client)
    assert length(recorded_requests(requests)) == 1
    assert Agent.get(sleeps, &Enum.reverse/1) == []
  end

  test "normalizes server errors", %{client: client} do
    client =
      put_in(client.req_options[:adapter], fn request ->
        response = Req.Response.json(%Req.Response{status: 401}, %{error: "invalid token"})
        {request, response}
      end)

    assert {:error, %Error{status: 401, reason: :invalid_token, message: "invalid token"}} =
             ExironClient.requests(client)
  end

  test "prefers stable server codes over fallback message normalization", %{client: client} do
    client =
      put_in(client.req_options[:adapter], fn request ->
        response =
          Req.Response.json(%Req.Response{status: 409}, %{
            code: "request_in_flight",
            error: "localized or changed message"
          })

        {request, response}
      end)

    assert {:error,
            %Error{
              code: "request_in_flight",
              reason: :request_in_flight,
              message: "localized or changed message"
            }} = ExironClient.requests(client)
  end

  test "detects hook already connected errors", %{client: client} do
    client =
      put_in(client.req_options[:adapter], fn request ->
        response =
          Req.Response.json(%Req.Response{status: 409}, contract_json("error_response.json"))

        {request, response}
      end)

    assert {:error,
            %Error{
              status: 409,
              reason: :hook_already_connected,
              message: "hook already connected",
              retry_after_ms: 3000
            } = error} = ExironClient.requests(client)

    assert Error.hook_already_connected?(error)
  end

  test "detects Telegram delivery timeout errors", %{client: client} do
    client =
      put_in(client.req_options[:adapter], fn request ->
        response =
          Req.Response.json(%Req.Response{status: 504}, %{
            error: "telegram delivery result timed out"
          })

        {request, response}
      end)

    assert {:error,
            %Error{
              status: 504,
              reason: :telegram_delivery_timeout,
              message: "telegram delivery result timed out"
            } = error} = ExironClient.push_text(client, "hello")

    assert Error.telegram_delivery_timeout?(error)
    refute Error.hook_already_connected?(error)
  end

  test "rejects malformed message payloads", %{client: client} do
    client =
      put_in(client.req_options[:adapter], fn request ->
        response =
          Req.Response.json(%Req.Response{status: 200}, %{
            requests: [
              %{
                msgtype: "request",
                req_id: "req-1",
                datatype: "text",
                data: "not base64"
              }
            ]
          })

        {request, response}
      end)

    assert {:error,
            %Error{reason: :invalid_response, message: "message data is not valid base64"}} =
             ExironClient.requests(client)
  end
end
