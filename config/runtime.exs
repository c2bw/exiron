import Config

unless Code.ensure_loaded?(Exiron.RuntimeConfig) do
  Code.require_file(Path.expand("../lib/exiron/runtime_config.ex", __DIR__))
end

alias Exiron.RuntimeConfig

metrics_token =
  case {RuntimeConfig.env(:metrics_token), RuntimeConfig.env(:metrics_token_file)} do
    {nil, path} when is_binary(path) -> path |> File.read!() |> String.trim()
    {token, _path} -> token
  end

config :exiron, :metrics_token, metrics_token
config :exiron, :group_albums, RuntimeConfig.from_env(:group_albums)

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/exiron start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if RuntimeConfig.env(:phx_server) do
  config :exiron, ExironWeb.Endpoint, server: true
end

config :exiron, ExironWeb.Endpoint,
  http: [port: String.to_integer(RuntimeConfig.env(:port, "4000"))]

trusted_proxies =
  RuntimeConfig.env(:trusted_proxies, "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

config :exiron, trusted_proxies: trusted_proxies

if config_env() != :test do
  telegram_pollers_enabled? = config_env() != :dev

  config :exiron,
    dashboard_session_max_age_seconds: RuntimeConfig.from_env(:dashboard_session_max_age_seconds)

  config :exiron, :hub,
    enabled: RuntimeConfig.from_env(:enabled),
    config_path: RuntimeConfig.from_env(:config_path),
    client_timeout: RuntimeConfig.from_env(:client_timeout),
    pending_timeout: RuntimeConfig.from_env(:pending_timeout),
    send_timeout: RuntimeConfig.from_env(:send_timeout),
    max_pending: RuntimeConfig.from_env(:max_pending),
    max_queue_per_hook: RuntimeConfig.from_env(:max_queue_per_hook),
    max_queue_bytes_per_hook: RuntimeConfig.from_env(:max_queue_bytes_per_hook),
    max_buffered_bytes: RuntimeConfig.from_env(:max_buffered_bytes),
    max_event_image_preview_bytes: RuntimeConfig.from_env(:max_event_image_preview_bytes),
    max_event_image_history_bytes: RuntimeConfig.from_env(:max_event_image_history_bytes),
    max_in_flight_sends: RuntimeConfig.from_env(:max_in_flight_sends),
    max_in_flight_send_bytes: RuntimeConfig.from_env(:max_in_flight_send_bytes),
    max_in_flight_send_bytes_per_hook: RuntimeConfig.from_env(:max_in_flight_send_bytes_per_hook),
    max_in_flight_sends_per_hook: RuntimeConfig.from_env(:max_in_flight_sends_per_hook),
    telegram_pollers_enabled:
      RuntimeConfig.from_env(:telegram_pollers_enabled, telegram_pollers_enabled?)

  if RuntimeConfig.env_present?(:api_body_length) do
    config :exiron,
      api_body_length: RuntimeConfig.from_env(:api_body_length)
  end
end

if dashboard_password = RuntimeConfig.env(:dashboard_password) do
  config :exiron, :dashboard_password, dashboard_password
end

if config_env() == :prod do
  if RuntimeConfig.env(:dashboard_password, "") == "" do
    raise """
    environment variable EXIRON_DASHBOARD_PASSWORD is missing.
    Set it to the password required for browser dashboard access.
    """
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    RuntimeConfig.env(:secret_key_base) ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = RuntimeConfig.env(:phx_host) || "example.com"

  config :exiron, :dns_cluster_query, RuntimeConfig.env(:dns_cluster_query)

  config :exiron, ExironWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :exiron, ExironWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :exiron, ExironWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
