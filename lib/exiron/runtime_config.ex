defmodule Exiron.RuntimeConfig do
  @moduledoc false

  @env_names %{
    api_body_length: "EXIRON_API_BODY_LENGTH",
    config_path: "EXIRON_CONFIG",
    dashboard_password: "EXIRON_DASHBOARD_PASSWORD",
    dashboard_session_max_age_seconds: "EXIRON_DASHBOARD_SESSION_MAX_AGE_SECONDS",
    dns_cluster_query: "DNS_CLUSTER_QUERY",
    enabled: "EXIRON_ENABLED",
    group_albums: "EXIRON_GROUP_ALBUMS",
    max_event_image_history_bytes: "EXIRON_MAX_EVENT_IMAGE_HISTORY_BYTES",
    max_event_image_preview_bytes: "EXIRON_MAX_EVENT_IMAGE_PREVIEW_BYTES",
    max_in_flight_sends: "EXIRON_MAX_IN_FLIGHT_SENDS",
    max_in_flight_send_bytes: "EXIRON_MAX_IN_FLIGHT_SEND_BYTES",
    max_in_flight_send_bytes_per_hook: "EXIRON_MAX_IN_FLIGHT_SEND_BYTES_PER_HOOK",
    max_in_flight_sends_per_hook: "EXIRON_MAX_IN_FLIGHT_SENDS_PER_HOOK",
    max_pending: "EXIRON_MAX_PENDING",
    metrics_token: "EXIRON_METRICS_TOKEN",
    metrics_token_file: "EXIRON_METRICS_TOKEN_FILE",
    max_queue_bytes_per_hook: "EXIRON_MAX_QUEUE_BYTES_PER_HOOK",
    max_buffered_bytes: "EXIRON_MAX_BUFFERED_BYTES",
    max_queue_per_hook: "EXIRON_MAX_QUEUE_PER_HOOK",
    pending_timeout: "EXIRON_PENDING_TIMEOUT_MS",
    phx_host: "PHX_HOST",
    phx_server: "PHX_SERVER",
    port: "PORT",
    secret_key_base: "SECRET_KEY_BASE",
    send_timeout: "EXIRON_SEND_TIMEOUT_MS",
    telegram_pollers_enabled: "EXIRON_TELEGRAM_POLLERS_ENABLED",
    trusted_proxies: "EXIRON_TRUSTED_PROXIES",
    client_timeout: "EXIRON_CLIENT_TIMEOUT_MS"
  }

  @settings %{
    api_body_length: %{parser: :positive_integer, default: 51 * 1024 * 1024, minimum: 1},
    client_timeout: %{parser: :positive_integer, default: 3_000, minimum: 1},
    config_path: %{parser: :string, default: "config/config.yml"},
    dashboard_session_max_age_seconds: %{
      parser: :positive_integer,
      default: 60 * 24 * 60 * 60,
      minimum: 1
    },
    enabled: %{parser: :boolean, default: true},
    group_albums: %{parser: :boolean, default: false},
    max_event_image_history_bytes: %{
      parser: :non_negative_integer,
      default: 64 * 1024 * 1024,
      minimum: 0
    },
    max_event_image_preview_bytes: %{
      parser: :non_negative_integer,
      default: 8 * 1024 * 1024,
      minimum: 0
    },
    max_in_flight_send_bytes: %{parser: :positive_integer, default: 256 * 1024 * 1024, minimum: 1},
    max_in_flight_send_bytes_per_hook: %{
      parser: :positive_integer,
      default: 64 * 1024 * 1024,
      minimum: 1
    },
    max_in_flight_sends: %{parser: :positive_integer, default: 100, minimum: 1},
    max_in_flight_sends_per_hook: %{parser: :positive_integer, default: 10, minimum: 1},
    max_pending: %{parser: :positive_integer, default: 1_000, minimum: 1},
    max_buffered_bytes: %{parser: :positive_integer, default: 256 * 1024 * 1024, minimum: 1},
    max_queue_bytes_per_hook: %{
      parser: :positive_integer,
      default: 50 * 1024 * 1024,
      minimum: 1
    },
    max_queue_per_hook: %{parser: :positive_integer, default: 100, minimum: 1},
    pending_timeout: %{parser: :positive_integer, default: 600_000, minimum: 1},
    send_timeout: %{parser: :positive_integer, default: 30_000, minimum: 1},
    telegram_pollers_enabled: %{parser: :boolean, default: true}
  }

  @schema_default :runtime_config_schema_default

  @spec env_name(atom()) :: String.t()
  def env_name(setting), do: Map.fetch!(@env_names, setting)

  @spec env(atom()) :: String.t() | nil
  def env(setting), do: System.get_env(env_name(setting))

  @spec env(atom(), String.t()) :: String.t()
  def env(setting, default), do: System.get_env(env_name(setting), default)

  @spec env_present?(atom()) :: boolean()
  def env_present?(setting), do: env(setting) != nil

  @spec default(atom()) :: term()
  def default(setting), do: setting!(setting).default

  @spec minimum(atom()) :: non_neg_integer()
  def minimum(setting), do: setting!(setting).minimum

  @spec from_env(atom()) :: term()
  def from_env(setting), do: from_env(setting, @schema_default)

  @spec from_env(atom(), term()) :: term()
  def from_env(setting, default_override) do
    setting_config = setting!(setting)

    default =
      if default_override == @schema_default, do: setting_config.default, else: default_override

    parse(setting_config.parser, env(setting), env_name(setting), default)
  end

  @spec configured(keyword(), atom()) :: term()
  def configured(opts, setting) do
    value = Keyword.get(opts, setting, default(setting))
    normalize(setting, value)
  end

  @spec normalize(atom(), term()) :: term()
  def normalize(setting, value) do
    case setting!(setting).parser do
      parser when parser in [:positive_integer, :non_negative_integer] ->
        max(value, minimum(setting))

      :boolean ->
        value

      :string ->
        value
    end
  end

  @spec parse_boolean(String.t() | nil, boolean()) :: boolean()
  def parse_boolean(nil, default), do: default

  def parse_boolean(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      value when value in ["false", "0", "no", "off"] -> false
      value when value in ["true", "1", "yes", "on"] -> true
      _value -> default
    end
  end

  def parse_boolean(_value, default), do: default

  @spec parse_positive_integer(atom() | String.t(), String.t() | nil, pos_integer()) ::
          pos_integer()
  def parse_positive_integer(name, value, default),
    do: parse_integer(name, value, default, 1, "positive")

  @spec parse_non_negative_integer(atom() | String.t(), String.t() | nil, non_neg_integer()) ::
          non_neg_integer()
  def parse_non_negative_integer(name, value, default),
    do: parse_integer(name, value, default, 0, "non-negative")

  defp parse_integer(_name, nil, default, _minimum, _description), do: default

  defp parse_integer(name, value, _default, minimum, description) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {integer, ""} when integer >= minimum -> integer
      _error -> invalid_integer!(name, description)
    end
  end

  defp parse_integer(name, _value, _default, _minimum, description),
    do: invalid_integer!(name, description)

  defp invalid_integer!(name, description),
    do: raise("environment variable #{name} must be a #{description} integer.")

  defp setting!(setting), do: Map.fetch!(@settings, setting)

  defp parse(:boolean, value, _name, default), do: parse_boolean(value, default)

  defp parse(:positive_integer, value, name, default),
    do: parse_positive_integer(name, value, default)

  defp parse(:non_negative_integer, value, name, default),
    do: parse_non_negative_integer(name, value, default)

  defp parse(:string, value, _name, default), do: value || default
end
