defmodule Exiron.Hub.RouteConfiguration.Encoder do
  @moduledoc false

  alias Exiron.Hub.RouteConfiguration.Document
  import Exiron.Hub.RouteConfiguration.Values, only: [list_or_empty: 1, map_or_empty: 1]

  # GUI mutations intentionally write a canonical config containing the supported
  # sections below. Comments and unknown top-level sections are not preserved.
  def encode(definitions) do
    [
      encode_version(Document.version(definitions)),
      encode_telegram(section(definitions, "telegram")),
      encode_routes(section(definitions, "routes")),
      encode_middlewares(section(definitions, "middlewares")),
      encode_hooks(section(definitions, "hooks"))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim_trailing("\n")
    |> Kernel.<>("\n")
  end

  defp section(definitions, name), do: map_or_empty(Map.get(definitions, name))

  defp encode_version(version) do
    "version: #{quote_string(version)}\n"
  end

  defp encode_telegram(telegram) do
    bots = telegram |> Map.get("bots") |> list_or_empty()

    encode_section(bots, fn ->
      entries =
        bots
        |> Enum.map(&map_or_empty/1)
        |> Enum.map(&encode_telegram_bot/1)
        |> Enum.join("\n")

      "telegram:\n  bots:\n#{entries}\n"
    end)
  end

  defp encode_telegram_bot(bot) do
    [
      "    - token: #{quote_string(Map.get(bot, "token", ""))}",
      bot |> Map.get("name") |> optional_yaml_line("      name"),
      "      chats:",
      bot |> Map.get("chats") |> map_or_empty() |> encode_chat_lines()
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp encode_chat_lines(chats) do
    chats
    |> sort_entries()
    |> Enum.map(fn {alias, chat_id} -> "        #{yaml_key(alias)}: #{chat_id}" end)
    |> Enum.join("\n")
  end

  defp optional_yaml_line(nil, _key), do: ""
  defp optional_yaml_line("", _key), do: ""
  defp optional_yaml_line(value, key), do: "#{key}: #{yaml_scalar(value)}"

  defp encode_routes(routes) do
    encode_section(routes, fn ->
      entries =
        routes
        |> sort_entries()
        |> Enum.map(fn {alias, route} ->
          route = map_or_empty(route)

          [
            "  #{yaml_key(alias)}:",
            yaml_list("    middleware", route |> Map.get("middleware") |> list_or_empty()),
            "    push: #{Map.get(route, "push", false)}",
            route |> Map.get("default_bot") |> optional_yaml_line("    default_bot")
          ]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")
        end)
        |> Enum.join("\n")

      "routes:\n#{entries}\n"
    end)
  end

  defp encode_middlewares(middlewares) do
    encode_section(middlewares, fn ->
      entries =
        middlewares
        |> sort_entries()
        |> Enum.map(fn {name, middleware} ->
          routes = middleware |> map_or_empty() |> Map.get("routes") |> map_or_empty()

          route_lines =
            routes
            |> sort_entries()
            |> Enum.map(&encode_middleware_route/1)
            |> Enum.join("\n")

          ["  #{yaml_key(name)}:", "    routes:", route_lines]
          |> Enum.join("\n")
        end)
        |> Enum.join("\n")

      "middlewares:\n#{entries}\n"
    end)
  end

  defp encode_middleware_route({hook, requirements}) do
    requirements = map_or_empty(requirements)
    messages = requirements |> Map.get("messages") |> list_or_empty()
    passthrough = Map.get(requirements, "passthrough", false) == true

    [
      "      #{yaml_key(hook)}:",
      yaml_list("        messages", messages),
      if(passthrough, do: "        passthrough: true", else: ""),
      Exiron.Hub.InteractionPolicy.encode(Map.get(requirements, "interaction"))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp encode_hooks(hooks) do
    encode_section(hooks, fn ->
      entries =
        hooks
        |> sort_entries()
        |> Enum.map(fn {hook, token} ->
          hashed = token |> to_string() |> Exiron.Hub.HookToken.hash()
          "  #{yaml_key(hook)}: #{yaml_scalar(hashed)}"
        end)
        |> Enum.join("\n")

      "hooks:\n#{entries}\n"
    end)
  end

  defp encode_section(empty, _fun) when empty in [%{}, []], do: ""
  defp encode_section(_value, fun), do: fun.()

  defp sort_entries(entries), do: Enum.sort_by(entries, fn {key, _value} -> key end)

  defp yaml_list(key, []), do: "#{key}: []"

  defp yaml_list(key, values) do
    indent =
      String.duplicate(" ", String.length(key) - String.length(String.trim_leading(key)) + 2)

    [
      "#{key}:",
      Enum.map_join(values, "\n", &"#{indent}- #{yaml_scalar(&1)}")
    ]
    |> Enum.join("\n")
  end

  defp yaml_key(value), do: yaml_scalar(to_string(value))

  defp quote_string(value), do: inspect(to_string(value))

  defp yaml_scalar(value) do
    value = to_string(value)

    if bare_yaml_scalar?(value), do: value, else: quote_string(value)
  end

  defp bare_yaml_scalar?(value) do
    Regex.match?(~r/^[A-Za-z0-9_@\/.-]+$/, value) and
      !Regex.match?(~r/^(?:true|false|null|nil|yes|no|on|off|y|n)$/i, value) and
      !Regex.match?(~r/^[+-]?\d+(?:\.\d+)?$/, value)
  end
end
