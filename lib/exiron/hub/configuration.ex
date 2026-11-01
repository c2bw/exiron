defmodule Exiron.Hub.Configuration do
  @moduledoc false

  alias Exiron.Hub.Configuration.BotParser
  alias Exiron.Hub.{HookToken, Router}
  alias Exiron.Hub.RouteConfiguration.Document

  @schema_version "2"

  @derive {Inspect, only: [:version, :aliases]}
  defstruct version: @schema_version,
            telegram: [],
            router: nil,
            definitions: %{},
            aliases: %{},
            source_digest: nil,
            source: nil

  def schema_version, do: @schema_version

  def read(path) do
    case File.read(path) do
      {:ok, data} -> read_source(data)
      {:error, :enoent} -> read_source(empty_source())
      {:error, reason} -> {:error, reason}
    end
  end

  def empty_source, do: "version: \"1\"\n"

  def read_source(source) when is_binary(source) do
    with {:ok, decoded} <- YamlElixir.read_from_string(source),
         {:ok, decoded} <- validate_root(decoded),
         {:ok, version} <- validate_version(decoded),
         :ok <- validate_hook_tokens(decoded),
         {:ok, {telegram, aliases}} <- BotParser.parse(decoded),
         {:ok, router_definitions} <- router_definitions(decoded, aliases),
         {:ok, router} <- Router.load_definitions(router_definitions) do
      {:ok,
       %__MODULE__{
         version: version,
         telegram: telegram,
         router: router,
         definitions: router_definitions,
         aliases: aliases,
         source_digest: :crypto.hash(:sha256, source),
         source: source
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_root(decoded) when is_map(decoded), do: {:ok, decoded}
  defp validate_root(_decoded), do: {:error, "configuration must be an object"}

  defp validate_version(decoded) do
    case Map.fetch(decoded, "version") do
      :error ->
        {:error, "configuration version is required"}

      {:ok, nil} ->
        {:error, "configuration version is required"}

      {:ok, version} when is_binary(version) ->
        case String.trim(version) do
          "" -> {:error, "configuration version is required"}
          supported when supported in ["1", @schema_version] -> {:ok, supported}
          other -> {:error, "unsupported configuration version: #{inspect(other)}"}
        end

      {:ok, _version} ->
        {:error, "configuration version must be a string"}
    end
  end

  defp validate_hook_tokens(decoded) do
    case Map.get(decoded, "hooks") do
      hooks when is_map(hooks) ->
        Enum.reduce_while(hooks, :ok, fn {name, token}, :ok ->
          if non_empty_string?(name) and non_empty_string?(token) and not HookToken.digest?(token) do
            {:halt,
             {:error, ~s(hook #{inspect(String.trim(name))} token must be a sha256 digest)}}
          else
            {:cont, :ok}
          end
        end)

      _other ->
        :ok
    end
  end

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp router_definitions(decoded, aliases) do
    # Router.load_definitions/1 accepts a service-agnostic routing document. The
    # top-level config keeps Telegram bot credentials separate and injects only
    # the alias map needed for routing decisions.
    {:ok, Document.with_router_aliases(decoded, aliases)}
  end
end
