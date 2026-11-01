defmodule ExironWeb.Plugs.TrustedSSL do
  @moduledoc false

  alias ExironWeb.Plugs.TrustedProxy

  @ssl_options Plug.SSL.init(
                 exclude: [
                   hosts: ["localhost", "127.0.0.1"]
                 ]
               )

  def init(opts), do: opts

  def call(conn, opts) do
    if enabled?(opts) do
      conn
      |> rewrite_forwarded_proto()
      |> Plug.SSL.call(@ssl_options)
    else
      conn
    end
  end

  defp enabled?(opts) do
    Keyword.get(opts, :enabled, Application.get_env(:exiron, :force_ssl, false))
  end

  defp rewrite_forwarded_proto(conn) do
    if TrustedProxy.trusted_peer?(conn) do
      Plug.RewriteOn.call(conn, [:x_forwarded_proto])
    else
      conn
    end
  end
end
