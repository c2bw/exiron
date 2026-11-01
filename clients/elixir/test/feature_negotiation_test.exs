defmodule ExironClient.FeatureNegotiationTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Error, PollerOptions, Protocol}
  @caps ["cooperative_cancellation", "handler_failure_reporting", "http_lease_renewal"]

  test "all enabled features share one discovery request" do
    parent = self()

    client =
      client(fn request ->
        send(parent, {:lookup, request.method, request.url.path})
        assert request.url.path == "/api/capabilities"
        Req.Response.json(%{protocol_version: "1.15", capabilities: @caps})
      end)

    config = PollerOptions.build!(options(client))
    assert config.handler_options[:cancellation_client]
    assert config.handler_options[:reporting_client]
    assert config.handler_options[:http_lease_renewal]
    assert_receive {:lookup, :get, "/api/capabilities"}
    refute_receive {:lookup, _, _}
  end

  test "older servers use one legacy lookup for all enabled features" do
    parent = self()

    for status <- [404, 405] do
      client =
        client(fn request ->
          send(parent, {:lookup, request.method, request.url.path})

          case request.url.path do
            "/api/capabilities" ->
              Req.Response.json(%Req.Response{status: status}, %{error: "unsupported"})

            "/api/auth" ->
              assert request.options.json == %{hook_token: "token"}

              Req.Response.json(%{
                auth_response: "OK",
                protocol_version: "1.13",
                capabilities: @caps
              })

            other ->
              flunk("unexpected work request #{other}")
          end
        end)

      assert PollerOptions.build!(options(client)).handler_options[:http_lease_renewal]
      assert_receive {:lookup, :get, "/api/capabilities"}
      assert_receive {:lookup, :post, "/api/auth"}
      refute_receive {:lookup, _, _}
    end
  end

  test "authentication failures, rate limits and server errors never fall back" do
    parent = self()

    for status <- [401, 403, 429, 500, 503] do
      client =
        client(fn request ->
          assert request.url.path == "/api/capabilities"
          send(parent, :lookup)
          Req.Response.json(%Req.Response{status: status}, %{error: "unavailable"})
        end)

      assert_raise ArgumentError, ~r/cannot negotiate/, fn ->
        PollerOptions.build!(options(client))
      end

      assert_receive :lookup
      refute_receive :lookup
    end
  end

  test "malformed discovery and transport failures never fall back" do
    for payload <- [
          %{},
          %{protocol_version: "1.15", capabilities: nil},
          %{protocol_version: "1.15", capabilities: [nil]},
          %{protocol_version: "1.15", capabilities: [""]}
        ] do
      client =
        client(fn request ->
          assert request.url.path == "/api/capabilities"
          Req.Response.json(payload)
        end)

      assert {:error, %Error{reason: :invalid_response}} = ExironClient.capabilities(client)
    end

    client =
      client(fn request ->
        assert request.url.path == "/api/capabilities"
        %Req.TransportError{reason: :econnrefused}
      end)

    assert {:error, %Error{reason: :transport_error}} = ExironClient.capabilities(client)
  end

  test "missing required support fails without requesting work or legacy auth" do
    client =
      client(fn request ->
        assert request.url.path == "/api/capabilities"
        Req.Response.json(%{protocol_version: "1.15", capabilities: []})
      end)

    assert_raise ArgumentError, ~r/does not support cooperative_cancellation/, fn ->
      PollerOptions.build!(options(client))
    end
  end

  test "reporting opt-out adds no requests and local validation precedes discovery" do
    client = client(fn _ -> flunk("unexpected negotiation before validation") end)

    assert PollerOptions.build!(
             runtime_reporting: false,
             client: client,
             handler: fn _ -> :ok end
           )

    for invalid <- [
          [handler_concurrency: 0],
          [handler: nil],
          [cancellation_interval_ms: 1],
          [on_connect: :bad],
          [interval_ms: 0],
          [transport: :websocket],
          [report_handler_failures: "true"]
        ] do
      assert_raise ArgumentError, fn ->
        PollerOptions.build!(Keyword.merge(options(client), invalid))
      end
    end
  end

  test "manual discovery returns protocol metadata without requiring a feature" do
    client =
      client(fn request ->
        assert request.url.path == "/api/capabilities"
        Req.Response.json(%{protocol_version: "1.15", capabilities: @caps})
      end)

    assert {:ok, %Protocol{version: "1.15"} = protocol} = ExironClient.capabilities(client)
    assert Protocol.supports?(protocol, "http_lease_renewal")
  end

  defp options(client),
    do: [
      client: client,
      handler: fn _ -> :ok end,
      transport: :http,
      cooperative_cancellation: true,
      report_handler_failures: true,
      http_lease_renewal: true
    ]

  defp client(response) do
    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [adapter: fn request -> {request, response.(request)} end]
      )

    %{client | reconnect_backoff: Keyword.put(client.reconnect_backoff, :max_retry_time_ms, 0)}
  end
end
