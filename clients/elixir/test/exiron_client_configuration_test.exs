defmodule ExironClient.ConfigurationTest do
  use ExUnit.Case, async: true

  test "normalizes supported base URLs" do
    assert ExironClient.new(base_url: "http://example.test/").base_url ==
             "http://example.test"

    assert ExironClient.new(base_url: "wss://example.test/exiron/").base_url ==
             "https://example.test/exiron"
  end

  test "rejects base URLs that cannot address Exiron HTTP endpoints" do
    invalid_urls = [
      "",
      "example.test",
      "ftp://example.test",
      "http:///missing-host",
      "http://example.test?token=secret",
      "http://example.test#fragment"
    ]

    for url <- invalid_urls do
      assert_raise ArgumentError,
                   "base_url must be an absolute HTTP or WebSocket URL without a query or fragment",
                   fn -> ExironClient.new(base_url: url) end
    end

    assert_raise ArgumentError, fn -> ExironClient.new(base_url: 123) end
  end
end
