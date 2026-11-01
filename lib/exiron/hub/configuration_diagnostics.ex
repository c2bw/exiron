defmodule Exiron.Hub.ConfigurationDiagnostics do
  @moduledoc false

  def analyze(config) do
    used = config.routes |> Enum.flat_map(& &1.middleware) |> MapSet.new()

    unused_hooks =
      for hook <- config.hooks, hook.route_count == 0 do
        warning(
          :unreachable_hook,
          [hook.name],
          "Hook #{inspect(hook.name)} has no resolved routes; incoming messages cannot reach it.",
          [{"Hook #{hook.name}", "exiron-hook-#{hook.name}"}]
        )
      end

    unused_middlewares =
      for middleware <- config.middlewares, not MapSet.member?(used, middleware.name) do
        warning(
          :unused_middleware,
          [middleware.name],
          "Middleware #{inspect(middleware.name)} is not used by any chat route.",
          [{"Middleware #{middleware.name}", "exiron-middleware-#{middleware.name}"}]
        )
      end

    empty_push =
      for route <- config.routes, route.push and route.hook_count == 0 do
        warning(
          :empty_push,
          [route.alias],
          "Chat route #{inspect(route.alias)} enables push but resolves to no destination hooks; no hook can push to this chat through this route.",
          [{"Chat #{route.alias}", "exiron-chat-route-#{route.alias}"}]
        )
      end

    (unused_hooks ++ unused_middlewares ++ empty_push ++ overlaps(config.resolved_routes))
    |> Enum.sort_by(&{&1.kind, &1.id})
  end

  defp overlaps(routes) do
    routes
    |> Enum.group_by(&{&1.service_id, &1.chat_id})
    |> Enum.flat_map(fn {_address, routes} ->
      prefixes = for route <- routes, prefix <- route.messages, do: {route, prefix}

      for {short_route, short} <- prefixes,
          {long_route, long} <- prefixes,
          {short_route.to, short_route.passthrough} != {long_route.to, long_route.passthrough},
          longer_command?(short, long) do
        warning(
          :overlapping_prefix,
          [short_route.id, short, long_route.id, long],
          "In chat #{inspect(short_route.chat_alias)}, #{inspect(long)} takes precedence over #{inspect(short)} by longest-prefix matching. #{overlap_effect(short_route, long_route)}",
          [
            {"#{short_route.chat_alias}: #{short}", "exiron-resolved-route-#{short_route.id}"},
            {"#{long_route.chat_alias}: #{long}", "exiron-resolved-route-#{long_route.id}"}
          ]
        )
      end
    end)
  end

  defp overlap_effect(%{to: hook}, %{to: hook}),
    do: "Both lead to #{inspect(hook)}, but their passthrough settings differ."

  defp overlap_effect(short, long),
    do: "The longer command goes to #{inspect(long.to)} instead of #{inspect(short.to)}."

  # Match Router's command boundary: /ai summary overlaps /ai, /aiv does not.
  defp longer_command?(short, long) do
    case String.split_at(long, String.length(short)) do
      {^short, rest} when rest != "" -> Regex.match?(~r/^\s/u, rest)
      _ -> false
    end
  end

  defp warning(kind, identity, message, targets) do
    id =
      :crypto.hash(:sha256, :erlang.term_to_binary({kind, identity}))
      |> Base.encode16(case: :lower)

    %{
      id: id,
      kind: kind,
      message: message,
      targets:
        Enum.map(targets, fn {label, id} ->
          %{label: label, href: "#" <> URI.encode(id, &URI.char_unreserved?/1)}
        end)
    }
  end
end
