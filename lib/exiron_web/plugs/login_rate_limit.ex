defmodule ExironWeb.Plugs.LoginRateLimit do
  @moduledoc false

  alias ExironWeb.Plugs.RateLimit

  @rate_limit_opts RateLimit.init(
                     limit: 10,
                     window_seconds: 60,
                     namespace: :dashboard_authentication
                   )

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", request_path: "/login"} = conn, _opts) do
    RateLimit.call(conn, @rate_limit_opts)
  end

  def call(conn, _opts), do: conn
end
