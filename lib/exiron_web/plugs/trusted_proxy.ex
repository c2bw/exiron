defmodule ExironWeb.Plugs.TrustedProxy do
  @moduledoc false

  import Bitwise
  import Plug.Conn, only: [get_req_header: 2, put_private: 3]

  @ipv4_bits 32
  @ipv6_bits 128
  @trusted_proxy_private :exiron_trusted_proxy

  def init(opts), do: opts

  def call(conn, opts) do
    trusted_proxies = Keyword.get_lazy(opts, :trusted_proxies, &configured_proxies/0)
    trusted? = trusted?(conn.remote_ip, trusted_proxies)
    conn = put_private(conn, @trusted_proxy_private, trusted?)

    if trusted? do
      case forwarded_addresses(conn) do
        {:ok, addresses} ->
          %{conn | remote_ip: client_address(addresses, conn.remote_ip, trusted_proxies)}

        :error ->
          conn
      end
    else
      conn
    end
  end

  def trusted_peer?(conn), do: Map.get(conn.private, @trusted_proxy_private, false)

  def validate_configuration!(trusted_proxies \\ configured_proxies()) do
    Enum.each(trusted_proxies, &parse_proxy!/1)
    :ok
  end

  defp configured_proxies do
    Application.get_env(:exiron, :trusted_proxies, [])
  end

  defp forwarded_addresses(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn address, {:ok, addresses} ->
      case parse_address(address) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | addresses]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, addresses} -> {:ok, Enum.reverse(addresses)}
      :error -> :error
    end
  end

  defp client_address([], peer, _trusted_proxies), do: peer

  defp client_address(forwarded, peer, trusted_proxies) do
    forwarded
    |> Kernel.++([peer])
    |> Enum.reverse()
    |> Enum.drop_while(&trusted?(&1, trusted_proxies))
    |> case do
      [address | _rest] -> address
      [] -> List.first(forwarded)
    end
  end

  defp trusted?(address, trusted_proxies) do
    Enum.any?(trusted_proxies, fn proxy ->
      {network, prefix_length, bit_length} = parse_proxy!(proxy)

      bit_length == address_bits(address) and
        same_prefix?(address, network, prefix_length, bit_length)
    end)
  end

  defp parse_proxy!(proxy) when is_binary(proxy) do
    case String.split(proxy, "/", parts: 2) do
      [address] ->
        parsed = parse_address!(address, proxy)
        {parsed, address_bits(parsed), address_bits(parsed)}

      [address, prefix] ->
        parsed = parse_address!(address, proxy)
        bit_length = address_bits(parsed)
        {parsed, parse_prefix!(prefix, bit_length, proxy), bit_length}
    end
  end

  defp parse_proxy!(proxy) do
    raise ArgumentError, "trusted proxy must be an IP address or CIDR, got: #{inspect(proxy)}"
  end

  defp parse_address!(address, proxy) do
    case parse_address(String.trim(address)) do
      {:ok, parsed} -> parsed
      :error -> raise ArgumentError, "invalid trusted proxy IP address or CIDR: #{inspect(proxy)}"
    end
  end

  defp parse_address(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, :einval} -> :error
    end
  end

  defp parse_prefix!(prefix, bit_length, proxy) do
    case prefix |> String.trim() |> Integer.parse() do
      {parsed, ""} when parsed >= 0 and parsed <= bit_length -> parsed
      _error -> raise ArgumentError, "invalid trusted proxy CIDR prefix: #{inspect(proxy)}"
    end
  end

  defp same_prefix?(address, network, prefix_length, bit_length) do
    shift = bit_length - prefix_length
    address_integer(address) >>> shift == address_integer(network) >>> shift
  end

  defp address_integer(address) do
    part_bits = div(address_bits(address), tuple_size(address))

    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, integer -> integer <<< part_bits ||| part end)
  end

  defp address_bits(address) when tuple_size(address) == 4, do: @ipv4_bits
  defp address_bits(address) when tuple_size(address) == 8, do: @ipv6_bits
end
