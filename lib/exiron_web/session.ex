defmodule ExironWeb.Session do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Session.init(opts)

  @impl true
  def call(conn, config) do
    cookie_opts =
      config.cookie_opts
      |> Keyword.put(:max_age, max_age_seconds())
      |> maybe_require_secure_cookie()

    Plug.Session.call(conn, %{config | cookie_opts: cookie_opts})
  end

  def max_age_seconds do
    Application.fetch_env!(:exiron, :dashboard_session_max_age_seconds)
  end

  defp secure_cookie? do
    Application.get_env(:exiron, :secure_session_cookie, false)
  end

  defp maybe_require_secure_cookie(cookie_opts) do
    if secure_cookie?(), do: Keyword.put(cookie_opts, :secure, true), else: cookie_opts
  end
end
