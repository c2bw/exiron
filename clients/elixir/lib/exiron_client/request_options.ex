defmodule ExironClient.RequestOptions do
  @moduledoc false

  def merge(base, overrides) do
    Keyword.merge(base, overrides, fn
      :finch, base, override -> Keyword.merge(base, override)
      _key, _base, override -> override
    end)
  end

  def control(client_options, opts, timeout \\ 1000) do
    finch =
      client_options
      |> Keyword.get(:finch, [])
      |> Keyword.put(:pool_timeout, timeout)
      |> Keyword.put(:receive_timeout, timeout)

    # Fixed connection settings reuse a pool; named pools keep their own configuration.
    finch =
      if Keyword.has_key?(finch, :name) do
        finch
      else
        conn_opts = Keyword.get(finch, :conn_opts, [])

        transport_opts =
          conn_opts |> Keyword.get(:transport_opts, []) |> Keyword.put(:timeout, timeout)

        Keyword.put(finch, :conn_opts, Keyword.put(conn_opts, :transport_opts, transport_opts))
      end

    opts |> Keyword.put(:receive_timeout, timeout) |> Keyword.put(:finch, finch)
  end
end
