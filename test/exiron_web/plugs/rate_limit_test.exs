defmodule ExironWeb.Plugs.RateLimitTest do
  use ExironWeb.ConnCase, async: false

  alias ExironWeb.Plugs.RateLimit
  alias ExironWeb.Plugs.RateLimit.Cleaner
  alias ExironWeb.Plugs.TrustedProxy

  setup do
    table = :rate_limit_test_entries

    reset_ets_table(table)

    %{table: table}
  end

  test "allows requests within the limit", %{conn: conn, table: table} do
    opts = RateLimit.init(limit: 3, window_seconds: 60, table: table)

    conn = RateLimit.call(conn, opts)
    assert conn.status != 429
    refute conn.halted
  end

  test "blocks requests exceeding the limit", %{conn: conn, table: table} do
    opts = RateLimit.init(limit: 2, window_seconds: 60, table: table)

    conn1 = RateLimit.call(conn, opts)
    assert conn1.status != 429

    conn2 = RateLimit.call(conn, opts)
    assert conn2.status != 429

    conn3 = RateLimit.call(conn, opts)
    assert conn3.status == 429
    assert conn3.halted

    assert Jason.decode!(conn3.resp_body) == %{
             "code" => "rate_limited",
             "error" => "too many requests"
           }
  end

  test "counts requests from earlier seconds inside the sliding window", %{
    conn: conn,
    table: table
  } do
    opts = RateLimit.init(limit: 2, window_seconds: 60, table: table)
    now = System.system_time(:second)
    :ets.insert(table, {{:default, "127.0.0.1", now - 1}, 2})

    conn = RateLimit.call(conn, opts)

    assert conn.status == 429
    assert conn.halted
  end

  test "atomically blocks concurrent requests beyond the limit", %{conn: conn, table: table} do
    opts = RateLimit.init(limit: 5, window_seconds: 60, table: table)

    statuses =
      1..20
      |> Task.async_stream(
        fn _index ->
          conn
          |> RateLimit.call(opts)
          |> Map.get(:status)
        end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.count(statuses, &is_nil/1) == 5
    assert Enum.count(statuses, &(&1 == 429)) == 15
    assert :ets.info(table, :size) == 1
  end

  test "request work is independent of unrelated ETS entries", %{
    conn: conn,
    table: table
  } do
    now = System.system_time(:second)
    current_key = {:default, "127.0.0.1", now}
    :ets.insert(table, {{:default, "127.0.0.1", now - 1}, 1})

    Enum.each(1..1_000, fn index ->
      :ets.insert(table, {{:unrelated, "identity-#{index}", now}, 1})
    end)

    opts = RateLimit.init(limit: 10, window_seconds: 60, table: table)
    refute RateLimit.call(conn, opts).halted

    assert [{^current_key, 1}] = :ets.lookup(table, current_key)
    assert :ets.info(table, :size) == 1_002
  end

  test "supports a one-second window", %{conn: conn, table: table} do
    opts = RateLimit.init(limit: 1, window_seconds: 1, table: table)

    refute RateLimit.call(conn, opts).halted
    assert RateLimit.call(conn, opts).halted
  end

  test "includes retry-after header when rate limited", %{conn: conn, table: table} do
    opts = RateLimit.init(limit: 1, window_seconds: 60, table: table)

    _conn1 = RateLimit.call(conn, opts)
    conn2 = RateLimit.call(conn, opts)

    assert conn2.status == 429
    assert get_resp_header(conn2, "retry-after") != []
  end

  test "retry-after waits until enough counted requests expire", %{conn: conn, table: table} do
    now = System.system_time(:second)
    :ets.insert(table, {{:default, "127.0.0.1", now - 30}, 2})
    :ets.insert(table, {{:default, "127.0.0.1", now - 20}, 1})

    opts = RateLimit.init(limit: 2, window_seconds: 60, table: table)
    conn = RateLimit.call(conn, opts)

    assert conn.status == 429
    [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..30
  end

  test "keeps independent policy namespaces isolated", %{conn: conn, table: table} do
    api_opts =
      RateLimit.init(
        limit: 100,
        window_seconds: 60,
        table: table,
        namespace: :api
      )

    auth_opts =
      RateLimit.init(
        limit: 1,
        window_seconds: 60,
        table: table,
        namespace: :authentication
      )

    Enum.each(1..10, fn _request ->
      refute RateLimit.call(conn, api_opts).halted
    end)

    refute RateLimit.call(conn, auth_opts).halted
    assert RateLimit.call(conn, auth_opts).halted
    refute RateLimit.call(conn, api_opts).halted
  end

  test "keeps bearer token budgets isolated behind the same IP", %{conn: conn, table: table} do
    opts =
      RateLimit.init(
        limit: 1,
        window_seconds: 60,
        table: table,
        namespace: :api_token,
        identity: :bearer
      )

    first = put_req_header(conn, "authorization", "Bearer first-token")
    second = put_req_header(conn, "authorization", "Bearer second-token")

    refute RateLimit.call(first, opts).halted
    assert RateLimit.call(first, opts).halted
    refute RateLimit.call(second, opts).halted
  end

  test "shares one bearer budget across source IPs", %{conn: conn, table: table} do
    opts =
      RateLimit.init(
        limit: 1,
        window_seconds: 60,
        table: table,
        namespace: :api_token,
        identity: :bearer
      )

    first = put_req_header(conn, "authorization", "Bearer shared-token")

    second =
      conn
      |> Map.put(:remote_ip, {10, 0, 0, 2})
      |> put_req_header("authorization", "Bearer shared-token")

    refute RateLimit.call(first, opts).halted
    assert RateLimit.call(second, opts).halted
  end

  test "does not store bearer credentials in ETS", %{conn: conn, table: table} do
    opts =
      RateLimit.init(
        limit: 1,
        window_seconds: 60,
        table: table,
        namespace: :api_token,
        identity: :bearer
      )

    secret = "secret-bearer-token"

    conn
    |> put_req_header("authorization", "Bearer #{secret}")
    |> RateLimit.call(opts)

    refute table |> :ets.tab2list() |> inspect() =~ secret
  end

  test "coarse IP policy still limits rotating bearer tokens", %{conn: conn, table: table} do
    opts =
      RateLimit.init(
        limit: 2,
        window_seconds: 60,
        table: table,
        namespace: :api_ip,
        identity: :ip
      )

    Enum.each(["first", "second"], fn token ->
      request = put_req_header(conn, "authorization", "Bearer #{token}")
      refute RateLimit.call(request, opts).halted
    end)

    request = put_req_header(conn, "authorization", "Bearer third")
    assert RateLimit.call(request, opts).halted
  end

  test "keeps forwarded clients behind a trusted proxy in separate IP budgets", %{
    conn: conn,
    table: table
  } do
    opts = RateLimit.init(limit: 1, window_seconds: 60, table: table)
    proxy_opts = [trusted_proxies: ["10.0.0.0/8"]]

    first =
      conn
      |> Map.put(:remote_ip, {10, 0, 0, 2})
      |> put_req_header("x-forwarded-for", "198.51.100.10")
      |> TrustedProxy.call(proxy_opts)

    second =
      conn
      |> Map.put(:remote_ip, {10, 0, 0, 2})
      |> put_req_header("x-forwarded-for", "198.51.100.11")
      |> TrustedProxy.call(proxy_opts)

    refute RateLimit.call(first, opts).halted
    refute RateLimit.call(second, opts).halted
    assert RateLimit.call(first, opts).halted
  end

  test "ignores forwarded addresses from untrusted peers", %{conn: conn, table: table} do
    opts = RateLimit.init(limit: 1, window_seconds: 60, table: table)
    proxy_opts = [trusted_proxies: ["10.0.0.0/8"]]

    first =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 20})
      |> put_req_header("x-forwarded-for", "198.51.100.10")
      |> TrustedProxy.call(proxy_opts)

    second =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 20})
      |> put_req_header("x-forwarded-for", "198.51.100.11")
      |> TrustedProxy.call(proxy_opts)

    refute RateLimit.call(first, opts).halted
    assert RateLimit.call(second, opts).halted
    assert first.remote_ip == {203, 0, 113, 20}
  end

  test "walks forwarded chains from the trusted peer toward the client", %{conn: conn} do
    forwarded =
      conn
      |> Map.put(:remote_ip, {10, 0, 0, 3})
      |> put_req_header("x-forwarded-for", "192.0.2.99, 198.51.100.10, 10.0.0.2")
      |> TrustedProxy.call(trusted_proxies: ["10.0.0.0/8"])

    assert forwarded.remote_ip == {198, 51, 100, 10}
  end

  test "supports trusted IPv6 proxy ranges", %{conn: conn} do
    forwarded =
      conn
      |> Map.put(:remote_ip, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 2})
      |> put_req_header("x-forwarded-for", "2001:db9::10")
      |> TrustedProxy.call(trusted_proxies: ["2001:db8::/32"])

    assert forwarded.remote_ip == {0x2001, 0xDB9, 0, 0, 0, 0, 0, 0x10}
  end

  test "keeps the peer address when a forwarded chain is malformed", %{conn: conn} do
    forwarded =
      conn
      |> Map.put(:remote_ip, {10, 0, 0, 3})
      |> put_req_header("x-forwarded-for", "not-an-ip, 198.51.100.10")
      |> TrustedProxy.call(trusted_proxies: ["10.0.0.0/8"])

    assert forwarded.remote_ip == {10, 0, 0, 3}
  end

  test "validates trusted proxy IP and CIDR configuration" do
    assert :ok =
             TrustedProxy.validate_configuration!([
               "127.0.0.1",
               "10.0.0.0/8",
               "2001:db8::/32"
             ])

    assert_raise ArgumentError, fn ->
      TrustedProxy.validate_configuration!(["10.0.0.0/99"])
    end
  end

  test "cleaner prunes stale entries and keeps active ones", %{table: table} do
    current_bucket = System.system_time(:second)

    stale_key = {:authentication, "127.0.0.1", current_bucket - 120}
    active_key = {:api, "10.0.0.1", current_bucket}
    :ets.insert(table, {stale_key, 1})
    :ets.insert(table, {active_key, 1})

    Cleaner.cleanup(table, 60)

    refute :ets.member(table, stale_key)
    assert :ets.member(table, active_key)
  end
end
