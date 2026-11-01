defmodule ExironClient.ReconnectionTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Error, ReconnectPolicy, Request, RetryAfter, SocketBackoff, SocketError}

  test "default jitter stays within half the capped delay; deterministic timing remains available" do
    client = ExironClient.new(base_url: "http://exiron.test")

    for base <- [1, 10, 100_000], _ <- 1..100 do
      backoff = Keyword.put(client.reconnect_backoff, :current_delay_ms, base)
      capped = min(base, backoff[:max_delay_ms])
      delay = ReconnectPolicy.delay_ms(backoff, Error.new(:transport_error, "offline"))
      assert delay >= div(capped, 2) and delay <= capped
    end

    backoff =
      client.reconnect_backoff
      |> Keyword.put(:jitter, false)
      |> Keyword.put(:current_delay_ms, 17)

    assert ReconnectPolicy.delay_ms(backoff, nil) == 17

    assert_raise ArgumentError, fn ->
      ExironClient.new(base_url: "http://exiron.test", reconnect_backoff: [jitter: :invalid])
    end
  end

  test "parses retry seconds and HTTP dates; keeps the longer body hint" do
    error = Error.new(:rate_limited, "limited", status: 429)
    assert RetryAfter.apply_header(error, [" 2 "]).retry_after_ms == 2000
    date = DateTime.utc_now() |> DateTime.add(60, :second) |> Req.Utils.format_http_date()
    delay = RetryAfter.apply_header(error, [date]).retry_after_ms
    assert delay > 55_000 and delay <= 60_000

    for header <- ["-1", "1.5", "garbage", "0", "", "Wed, 01 Jan 2020 00:00:00 GMT"] do
      assert RetryAfter.apply_header(error, [header]) == error
    end

    assert RetryAfter.apply_header(error, ["1", "2"]) == error
    assert RetryAfter.apply_header(%{error | retry_after_ms: 3000}, ["1"]).retry_after_ms == 3000
    assert RetryAfter.apply_header(%{error | status: 503}, ["1"]).retry_after_ms == nil
  end

  test "rate limit retries honor the hint only for safe operations" do
    for {method, path, opts, safe?} <- [
          {:get, "/api/status", [], true},
          {:get, "/api/capabilities", [], true},
          {:get, "/api/requests", [params: [delivery_mode: :explicit]], true},
          {:get, "/api/requests", [], false},
          {:post, "/api/auth", [], true},
          {:post, "/api/responses", [], false},
          {:post, "/api/push", [], false},
          {:post, "/api/idempotent/responses", [], false},
          {:post, "/api/client-lease", [], false}
        ] do
      {client, state} = client(["2", :ok])
      result = Request.request(client, method, path, opts)
      %{attempts: attempts, waits: waits} = Agent.get(state, & &1)

      if safe? do
        assert {:ok, %{}} = result
        assert attempts == 2 and waits == [2000]
      else
        assert {:error, %Error{status: 429, retry_after_ms: 2000}} = result
        assert attempts == 1 and waits == []
      end
    end
  end

  test "missing and malformed rate limit hints use bounded jitter" do
    for header <- [nil, "bad", "-1"] do
      {client, state} = client([header, :ok])
      assert {:ok, %{}} = Request.request(client, :get, "/api/status")
      assert %{attempts: 2, waits: [delay]} = Agent.get(state, & &1)
      assert delay in 5..10
    end
  end

  test "a hint beyond the retry budget does not sleep or send again" do
    for hint <- ["10", "99999999999999999999999999999"] do
      {client, state} = client([hint, :ok], max_retry_time_ms: 100)
      assert {:error, %Error{status: 429}} = Request.request(client, :get, "/api/status")
      assert %{attempts: 1, waits: []} = Agent.get(state, & &1)
    end
  end

  test "cancellation through the sleep hook stops before the next request" do
    {client, state} = client(["1", :ok], sleep: fn _ -> {:error, :cancelled} end)

    assert {:error, %Error{reason: :request_error, body: :cancelled}} =
             Request.request(client, :get, "/api/status")

    assert %{attempts: 1} = Agent.get(state, & &1)
  end

  test "websocket rate limits use jitter and preserve reconnect budget" do
    error =
      SocketError.disconnect_error(%WebSockex.RequestError{code: 429, message: "limited"}, %{})

    assert %Error{reason: :rate_limited, status: 429} = error
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        reconnect_backoff: [
          initial_delay_ms: 10,
          sleep: fn delay -> send(parent, {:delay, delay}) end
        ]
      )

    state = %ExironClient.SocketState{client: client}
    assert {:ok, next} = SocketBackoff.reconnect_after(state, error)
    assert_receive {:delay, delay}
    assert delay in 5..10
    assert next.client.reconnect_backoff[:current_delay_ms] == 20
    hint = %{error | retry_after_ms: 100_000}
    assert {:error, ^hint} = SocketBackoff.reconnect_after(state, hint)
    refute_received {:delay, _}
    assert SocketBackoff.reset(next).client.reconnect_backoff[:current_delay_ms] == 10
  end

  test "HTTP reconnect progression resets after a successful poll" do
    {client, _state} = client([:transport, :transport, :ok, :transport], max_retry_time_ms: 1)

    {:ok, state, {:continue, :poll}} =
      ExironClient.Poller.init(
        runtime_reporting: false,
        client: client,
        handler: fn _ -> :ok end,
        interval_ms: 10_000
      )

    {:noreply, state} = ExironClient.Poller.handle_continue(:poll, state)
    assert state.retry_delay_ms == 20_000
    {:noreply, state} = ExironClient.Poller.handle_continue(:poll, state)
    assert state.retry_delay_ms == 30_000
    {:noreply, state} = ExironClient.Poller.handle_continue(:poll, state)
    assert state.retry_delay_ms == nil
    {:noreply, state} = ExironClient.Poller.handle_continue(:poll, state)
    assert state.retry_delay_ms == 20_000
  end

  test "a rejected stream update is neither replayed nor finalized" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        req_options: [
          adapter: fn req ->
            payload = Jason.decode!(req.body)
            send(parent, {:update, payload["final"]})

            if payload["final"] == false do
              {req, Req.Response.json(%{ok: true, final: false, message_id: 901})}
            else
              {req,
               %Req.Response{
                 status: 429,
                 body: %{"error" => "limited"},
                 headers: %{"retry-after" => ["1"]}
               }}
            end
          end
        ]
      )

    assert {:error, %Error{status: 429}} =
             ExironClient.stream_text(client, "req-1", ["partial", " done"], interval_ms: 100_000)

    assert_received {:update, false}
    assert_received {:update, true}
    refute_received {:update, _}
  end

  defp client(responses, overrides \\ []) do
    state =
      start_supervised!({Agent, fn -> %{responses: responses, attempts: 0, waits: []} end},
        id: make_ref()
      )

    backoff =
      Keyword.merge(
        [
          initial_delay_ms: 10,
          max_retry_time_ms: 5000,
          sleep: fn delay -> Agent.update(state, &%{&1 | waits: &1.waits ++ [delay]}) end
        ],
        overrides
      )

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        reconnect_backoff: backoff,
        req_options: [
          adapter: fn req ->
            response =
              Agent.get_and_update(state, fn state ->
                [next | rest] = state.responses
                {next, %{state | responses: rest, attempts: state.attempts + 1}}
              end)

            case response do
              :transport ->
                {req, %Req.TransportError{reason: :econnrefused}}

              :ok ->
                {req, %Req.Response{status: 200, body: %{"requests" => []}}}

              header ->
                headers = if header, do: %{"retry-after" => [header]}, else: %{}

                {req,
                 %Req.Response{
                   status: 429,
                   body: %{"error" => "limited", "code" => "rate_limited"},
                   headers: headers
                 }}
            end
          end
        ]
      )

    {client, state}
  end
end
