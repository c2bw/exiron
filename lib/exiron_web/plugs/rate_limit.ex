defmodule ExironWeb.Plugs.RateLimit do
  @moduledoc """
  Identity-based rate limiter using ETS with sliding-window counters.

  The ETS table must be created before use (typically in the application
  supervisor). The current second is incremented atomically and prior seconds
  are read by exact ETS keys, so request cost is bounded by `:window_seconds`
  instead of the total table size. Stale buckets are pruned by the cleaner.

  ## Options

    * `:limit` - max requests per window (default: 10)
    * `:window_seconds` - window duration in seconds (default: 60)
    * `:table` - ETS table name (default: `:rate_limit_entries`)
    * `:namespace` - isolates counters for independent policies (default: `:default`)
    * `:identity` - counter identity, either `:ip` or `:bearer` (default: `:ip`).
      Bearer tokens are hashed before being used as ETS keys and missing tokens
      fall back to the remote IP.

  """

  import Plug.Conn

  alias ExironWeb.BearerToken
  alias Exiron.Protocol

  @defaults [
    limit: 10,
    window_seconds: 60,
    table: :rate_limit_entries,
    namespace: :default,
    identity: :ip
  ]

  def init(opts), do: Keyword.merge(@defaults, opts)

  def call(conn, opts) do
    table = Keyword.fetch!(opts, :table)
    limit = Keyword.fetch!(opts, :limit)
    window = Keyword.fetch!(opts, :window_seconds)
    namespace = Keyword.fetch!(opts, :namespace)
    identity = request_identity(conn, Keyword.fetch!(opts, :identity))
    now = System.system_time(:second)
    key = {namespace, identity, now}
    window_start = now - window + 1

    current_count = :ets.update_counter(table, key, {2, 1}, {key, 0})
    previous_buckets = previous_buckets(table, namespace, identity, window_start, now)
    total = count_total(previous_buckets, current_count)

    if total > limit do
      reject(
        conn,
        retry_after([{now, current_count} | previous_buckets], total, limit, now, window)
      )
    else
      conn
    end
  end

  defp request_identity(conn, :ip), do: ip_string(conn)

  defp request_identity(conn, :bearer) do
    case BearerToken.from_conn(conn) do
      token when token in [nil, ""] -> ip_string(conn)
      token -> bearer_fingerprint(token)
    end
  end

  defp bearer_fingerprint(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&("bearer:" <> &1))
  end

  defp reject(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(max(retry_after, 1)))
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(Protocol.error_payload(:rate_limited)))
    |> halt()
  end

  defp ip_string(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      tuple when is_tuple(tuple) -> tuple |> Tuple.to_list() |> Enum.join(":")
      _ -> "unknown"
    end
  end

  defp previous_buckets(_table, _namespace, _identity, window_start, now)
       when window_start >= now,
       do: []

  defp previous_buckets(table, namespace, identity, window_start, now) do
    Enum.reduce(window_start..(now - 1), [], fn bucket, entries ->
      key = {namespace, identity, bucket}

      case :ets.lookup(table, key) do
        [{^key, count}] -> [{bucket, count} | entries]
        [] -> entries
      end
    end)
  end

  defp count_total(previous_buckets, current_count) do
    Enum.reduce(previous_buckets, current_count, fn {_bucket, count}, total -> total + count end)
  end

  defp retry_after(entries, total, limit, now, window) do
    entries
    |> Enum.sort_by(fn {bucket, _count} -> bucket end)
    |> Enum.reduce_while(total, fn {bucket, count}, remaining ->
      remaining = remaining - count

      if remaining <= limit do
        {:halt, {:retry_after, bucket + window - now}}
      else
        {:cont, remaining}
      end
    end)
    |> case do
      {:retry_after, seconds} -> seconds
      _remaining -> window
    end
  end
end
