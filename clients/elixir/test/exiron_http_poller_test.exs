defmodule ExironClient.HTTPPollerTest do
  use ExUnit.Case, async: true

  alias ExironClient.{Error, Message}
  import ExironClient.FixtureHelpers

  @poller_assert_timeout 1_000

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

  @tag capture_log: true
  test "managed poller polls and handles messages", %{requests: requests} do
    ExUnit.CaptureLog.capture_log(fn ->
      parent = self()
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      client =
        ExironClient.new(
          base_url: "http://exiron.test/",
          token: "ai-token",
          client_id: "poller",
          req_options: [
            adapter: fn request ->
              Agent.update(requests, &[request | &1])
              attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

              if attempt == 1 do
                response_for(request)
              else
                Req.Response.json(%Req.Response{status: 409}, %{error: "stop"})
              end
              |> then(&{request, &1})
            end
          ]
        )

      pid =
        start_supervised!(
          {ExironClient.Poller,
           runtime_reporting: false,
           client: client,
           transport: :http,
           interval_ms: 10,
           handler: fn message ->
             send(parent, {:handled, message})
             :ok
           end},
          restart: :temporary
        )

      assert_receive {:handled, %Message{data: "/ai hello"}}, @poller_assert_timeout

      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, %Error{message: "stop"}},
                     @poller_assert_timeout

      [first_poll, second_poll] = recorded_requests(requests)

      assert URI.decode_query(first_poll.url.query) == %{
               "client_id" => "poller",
               "delivery_mode" => "explicit",
               "listen" => "false"
             }

      assert URI.decode_query(second_poll.url.query) == %{
               "client_id" => "poller",
               "delivery_ack" => "delivery-1",
               "delivery_mode" => "explicit",
               "listen" => "false"
             }
    end)
  end

  @tag capture_log: true
  test "managed poller reports connect and disconnect lifecycle", %{requests: requests} do
    parent = self()
    attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "poller",
        req_options: [
          adapter: fn request ->
            Agent.update(requests, &[request | &1])
            attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

            if attempt <= 2 do
              Req.Response.json(%{requests: []})
            else
              send(parent, {:fatal_poll_ready, self()})

              receive do
                :release_fatal_poll ->
                  Req.Response.json(%Req.Response{status: 409}, %{error: "stop"})
              end
            end
            |> then(&{request, &1})
          end
        ]
      )

    pid =
      start_supervised!(
        {ExironClient.Poller,
         runtime_reporting: false,
         client: client,
         transport: :http,
         interval_ms: 10,
         handler: fn _message -> :ok end,
         on_connect: fn -> send(parent, :connected) end,
         on_disconnect: fn reason -> send(parent, {:disconnected, reason}) end},
        restart: :temporary
      )

    assert_receive :connected, @poller_assert_timeout
    assert_receive {:fatal_poll_ready, ^pid}, @poller_assert_timeout

    ref = Process.monitor(pid)
    send(pid, :release_fatal_poll)

    assert_receive {:disconnected, %Error{message: "stop"}}, @poller_assert_timeout

    assert_receive {:DOWN, ^ref, :process, ^pid, %Error{message: "stop"}},
                   @poller_assert_timeout

    refute_receive :connected
  end

  test "managed poller reconnects after transport errors", %{requests: requests} do
    parent = self()
    attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "poller",
        req_options: [
          adapter: fn request ->
            Agent.update(requests, &[request | &1])

            response =
              case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
                1 -> Req.Response.json(%{requests: []})
                2 -> %Req.TransportError{reason: :econnrefused}
                _attempt -> Req.Response.json(%{requests: []})
              end

            {request, response}
          end
        ],
        reconnect_backoff: [
          jitter: false,
          initial_delay_ms: 2,
          max_delay_ms: 2,
          max_retry_time_ms: 1,
          sleep: fn _delay_ms -> :ok end
        ]
      )

    start_supervised!(
      {ExironClient.Poller,
       runtime_reporting: false,
       client: client,
       transport: :http,
       interval_ms: 10,
       handler: fn _message -> :ok end,
       on_connect: fn -> send(parent, :connected) end,
       on_disconnect: fn reason -> send(parent, {:disconnected, reason}) end}
    )

    assert_receive :connected, @poller_assert_timeout
    assert_receive {:disconnected, %Error{reason: :transport_error}}, @poller_assert_timeout
    assert_receive :connected, @poller_assert_timeout

    assert length(recorded_requests(requests)) >= 3
  end

  test "managed poller caps reconnect budget before reporting disconnect", %{requests: requests} do
    parent = self()
    attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())
    sleeps = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    client =
      ExironClient.new(
        base_url: "http://exiron.test/",
        token: "ai-token",
        client_id: "poller",
        req_options: [
          adapter: fn request ->
            Agent.update(requests, &[request | &1])

            response =
              case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
                1 -> Req.Response.json(%{requests: []})
                _attempt -> %Req.TransportError{reason: :econnrefused}
              end

            {request, response}
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

    start_supervised!(
      {ExironClient.Poller,
       runtime_reporting: false,
       client: client,
       transport: :http,
       interval_ms: 10,
       disconnect_timeout_ms: 1_000,
       handler: fn _message -> :ok end,
       on_connect: fn -> send(parent, :connected) end,
       on_disconnect: fn reason -> send(parent, {:disconnected, reason}) end}
    )

    assert_receive :connected, @poller_assert_timeout
    assert_receive {:disconnected, %Error{reason: :transport_error}}, @poller_assert_timeout

    assert Agent.get(sleeps, &Enum.reverse/1) |> Enum.take(2) == [250, 500]
  end

  @tag capture_log: true
  test "managed poller stops when the handler returns an error", %{client: client} do
    parent = self()

    pid =
      start_supervised!(
        {ExironClient.Poller,
         runtime_reporting: false,
         client: client,
         transport: :http,
         interval_ms: 10,
         handler: fn _message -> {:error, :handler_failed} end,
         on_connect: fn -> send(parent, :connected) end,
         on_disconnect: fn reason -> send(parent, {:disconnected, reason}) end},
        restart: :temporary
      )

    ref = Process.monitor(pid)
    assert_receive :connected, @poller_assert_timeout
    assert_receive {:disconnected, :handler_failed}, @poller_assert_timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, :handler_failed}, @poller_assert_timeout
  end

  @tag capture_log: true
  test "managed HTTP poller does not reinterpret handler client errors as transport errors", %{
    client: client,
    requests: requests
  } do
    parent = self()
    failure = Error.new(:transport_error, "handler request failed")

    pid =
      start_supervised!(
        {ExironClient.Poller,
         runtime_reporting: false,
         client: client,
         transport: :http,
         interval_ms: 10,
         handler: fn _message -> {:error, failure} end,
         on_connect: fn -> send(parent, :connected) end,
         on_disconnect: fn reason -> send(parent, {:disconnected, reason}) end},
        restart: :temporary
      )

    ref = Process.monitor(pid)
    assert_receive :connected, @poller_assert_timeout
    assert_receive {:disconnected, ^failure}, @poller_assert_timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, ^failure}, @poller_assert_timeout
    assert length(recorded_requests(requests)) == 1
  end
end
