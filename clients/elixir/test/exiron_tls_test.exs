defmodule ExironClient.TLSTest do
  use ExUnit.Case, async: true

  alias ExironClient.SocketPoller
  alias ExironClient.FixtureHelpers

  test "wss transport verifies certificates and hostnames by default" do
    client =
      FixtureHelpers.socket_client()
      |> Map.put(:base_url, "https://example.test")

    options = SocketPoller.websockex_options(client)
    ssl_options = options[:ssl_options]

    assert options[:insecure] == false
    assert ssl_options[:verify] == :verify_peer
    assert is_list(ssl_options[:cacerts])
    assert ssl_options[:server_name_indication] == ~c"example.test"
    assert Keyword.has_key?(ssl_options, :customize_hostname_check)
    assert {"authorization", "Bearer ai-token"} in options[:extra_headers]
    assert {"x-exiron-sdk", "elixir"} in options[:extra_headers]
    assert {"x-exiron-sdk-version", ExironClient.Version.current()} in options[:extra_headers]
    assert options[:handle_initial_conn_failure] == true
    assert options[:max_frame_size] == client.max_response_bytes
  end

  test "direct wss base URLs also use secure TLS defaults" do
    client =
      FixtureHelpers.socket_client()
      |> Map.put(:base_url, "wss://example.test")

    options = SocketPoller.websockex_options(client)

    assert options[:insecure] == false
    assert options[:ssl_options][:server_name_indication] == ~c"example.test"
  end

  test "ws transport does not add TLS options" do
    client = FixtureHelpers.socket_client()
    options = SocketPoller.websockex_options(client)

    refute Keyword.has_key?(options, :insecure)
    refute Keyword.has_key?(options, :ssl_options)
  end

  test "wss transport supports an explicit insecure development opt-out" do
    client =
      FixtureHelpers.socket_client()
      |> Map.put(:base_url, "https://example.test")
      |> Map.put(:allow_insecure_websocket_tls?, true)

    options = SocketPoller.websockex_options(client)

    assert options[:insecure] == true
    refute Keyword.has_key?(options, :ssl_options)
  end

  test "wss transport merges custom TLS options without weakening secure defaults" do
    custom_ca = {:cert, <<1, 2, 3>>}

    client =
      FixtureHelpers.socket_client()
      |> Map.put(:base_url, "https://example.test")
      |> Map.put(:websocket_tls_options, cacerts: [custom_ca], verify: :verify_none)

    ssl_options = SocketPoller.websockex_options(client)[:ssl_options]

    assert ssl_options[:cacerts] == [custom_ca]
    assert ssl_options[:verify] == :verify_peer
    assert ssl_options[:server_name_indication] == ~c"example.test"
  end

  test "configures secure websocket TLS defaults and explicit development opt-out" do
    custom_options = [cacerts: [{:cert, <<1, 2, 3>>}]]

    secure_client =
      ExironClient.new(
        base_url: "https://exiron.test",
        websocket_tls_options: custom_options
      )

    insecure_client =
      ExironClient.new(
        base_url: "https://exiron.test",
        allow_insecure_websocket_tls: true
      )

    assert secure_client.websocket_tls_options == custom_options
    refute secure_client.allow_insecure_websocket_tls?
    assert insecure_client.allow_insecure_websocket_tls?
  end

  test "validates websocket TLS option types" do
    assert_raise ArgumentError, ":websocket_tls_options must be a keyword list", fn ->
      ExironClient.new(base_url: "https://exiron.test", websocket_tls_options: [:invalid])
    end

    assert_raise ArgumentError, "allow_insecure_websocket_tls must be a boolean", fn ->
      ExironClient.new(base_url: "https://exiron.test", allow_insecure_websocket_tls: :yes)
    end
  end
end
