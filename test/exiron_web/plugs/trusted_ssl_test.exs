defmodule ExironWeb.Plugs.TrustedSSLTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ExironWeb.Plugs.{TrustedProxy, TrustedSSL}

  @trusted_proxies ["10.0.0.0/8"]

  test "ignores forwarded HTTPS from an untrusted peer" do
    conn =
      :get
      |> conn("http://example.com/dashboard")
      |> put_req_header("x-forwarded-proto", "https")
      |> TrustedProxy.call(trusted_proxies: @trusted_proxies)
      |> TrustedSSL.call(enabled: true)

    assert conn.halted
    assert conn.status == 301
    assert get_resp_header(conn, "location") == ["https://example.com/dashboard"]
  end

  test "honors forwarded HTTPS from a trusted proxy" do
    conn =
      :get
      |> conn("http://example.com/dashboard")
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header("x-forwarded-proto", "https")
      |> TrustedProxy.call(trusted_proxies: @trusted_proxies)
      |> TrustedSSL.call(enabled: true)

    refute conn.halted
    assert conn.scheme == :https
    assert get_resp_header(conn, "strict-transport-security") != []
  end

  test "redirects trusted proxy requests reported as HTTP" do
    conn =
      :get
      |> conn("http://example.com/dashboard")
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header("x-forwarded-proto", "http")
      |> TrustedProxy.call(trusted_proxies: @trusted_proxies)
      |> TrustedSSL.call(enabled: true)

    assert conn.halted
    assert conn.status == 301
  end

  test "does not enforce HTTPS when disabled" do
    conn =
      :get
      |> conn("http://example.com/dashboard")
      |> put_req_header("x-forwarded-proto", "https")
      |> TrustedProxy.call(trusted_proxies: @trusted_proxies)
      |> TrustedSSL.call(enabled: false)

    refute conn.halted
    assert conn.scheme == :http
  end
end
