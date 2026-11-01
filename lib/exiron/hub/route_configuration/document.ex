defmodule Exiron.Hub.RouteConfiguration.Document do
  @moduledoc false

  alias Exiron.Hub.Configuration

  import Exiron.Hub.RouteConfiguration.Values,
    only: [list_or_empty: 1, map_or_empty: 1, optional_string: 1]

  @sections ["version", "routes", "middlewares", "hooks"]

  def supported_sections(definitions) do
    Map.take(definitions, @sections)
  end

  def ensure_supported_sections(definitions) do
    definitions
    |> map_or_empty()
    |> ensure_version()
    |> ensure_path(["telegram"])
    |> ensure_path(["telegram", "bots"], [])
    |> ensure_path(["routes"])
    |> ensure_path(["middlewares"])
    |> ensure_path(["hooks"])
  end

  def version(definitions) do
    definitions
    |> map_or_empty()
    |> Map.get("version")
    |> case do
      value when is_binary(value) -> optional_string(value) || Configuration.schema_version()
      _other -> Configuration.schema_version()
    end
  end

  def telegram_bots(definitions) do
    definitions
    |> telegram_bots_value()
    |> list_or_empty()
  end

  def telegram_bots_value(definitions) do
    definitions
    |> Map.get("telegram")
    |> map_or_empty()
    |> Map.get("bots", [])
  end

  def routes(definitions), do: section_map(definitions, "routes")
  def middlewares(definitions), do: section_map(definitions, "middlewares")
  def hooks(definitions), do: section_map(definitions, "hooks")

  def with_router_aliases(definitions, aliases) do
    definitions
    |> supported_sections()
    |> Map.put("aliases", %{"telegram" => aliases})
  end

  defp section_map(definitions, section) do
    definitions
    |> Map.get(section)
    |> map_or_empty()
  end

  defp ensure_version(definitions) do
    Map.put(definitions, "version", version(definitions))
  end

  defp ensure_path(map, path, default \\ %{})

  defp ensure_path(map, [key], default),
    do: Map.update(map, key, default, &defaulted(&1, default))

  defp ensure_path(map, [key | rest], default) do
    child =
      map
      |> Map.get(key)
      |> map_or_empty()
      |> ensure_path(rest, default)

    Map.put(map, key, child)
  end

  defp defaulted(value, default) when is_list(default),
    do: if(is_list(value), do: value, else: default)

  defp defaulted(value, _default), do: map_or_empty(value)
end
