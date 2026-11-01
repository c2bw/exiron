defmodule Exiron.Hub.RouteConfiguration.Projection do
  @moduledoc false

  alias Exiron.Hub.{Configuration, HookToken, Router}
  alias Exiron.Hub.RouteConfiguration
  alias Exiron.Hub.RouteConfiguration.{Document, TelegramProjection}

  import Exiron.Hub.RouteConfiguration.Values,
    only: [
      map_or_empty: 1,
      middleware_messages: 1,
      middleware_passthrough: 1,
      route_default_bot: 1,
      route_middleware: 1,
      route_push: 1
    ]

  def from_configuration(path, source, %Configuration{} = configuration) do
    definitions = configuration.definitions
    aliases = configuration.aliases
    route_definitions = Document.routes(definitions)
    middleware_definitions = Document.middlewares(definitions)
    hooks = Document.hooks(definitions)

    resolved_routes = Router.snapshot(configuration.router)
    middlewares = middleware_entries(middleware_definitions)

    %RouteConfiguration{
      path: path,
      version: configuration.version,
      source: source,
      configuration: configuration,
      router: configuration.router,
      aliases: aliases,
      bots: TelegramProjection.bots(configuration.telegram, aliases),
      routes: route_entries(route_definitions, aliases, resolved_routes),
      middlewares: middlewares,
      hooks: hook_entries(hooks, resolved_routes, middlewares),
      resolved_routes: resolved_routes
    }
  end

  defp route_entries(routes, aliases, resolved_routes) do
    resolved_by_alias = Enum.group_by(resolved_routes, & &1.chat_alias)

    routes
    |> Enum.map(fn {alias, route} ->
      route = map_or_empty(route)
      resolved = Map.get(resolved_by_alias, alias, [])
      hooks = unique_sorted(resolved, & &1.to)
      messages = unique_sorted_many(resolved, & &1.messages)

      %{
        alias: alias,
        chat_id: Map.get(aliases, alias),
        middleware: route_middleware(route),
        push: route_push(route),
        default_bot: route_default_bot(route),
        hooks: hooks,
        hook_count: length(hooks),
        messages: messages,
        message_count: length(messages)
      }
    end)
    |> Enum.sort_by(& &1.alias)
  end

  defp middleware_entries(middlewares) do
    middlewares
    |> Enum.map(fn {name, middleware} ->
      routes =
        middleware
        |> map_or_empty()
        |> Map.get("routes")
        |> map_or_empty()
        |> Enum.map(&middleware_route_entry/1)
        |> Enum.sort_by(& &1.hook)

      %{name: name, routes: routes}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp middleware_route_entry({hook, requirements}) do
    %{
      hook: hook,
      messages: middleware_messages(requirements),
      passthrough: middleware_passthrough(requirements)
    }
  end

  defp hook_entries(hooks, resolved_routes, middlewares) do
    resolved_by_hook = Enum.group_by(resolved_routes, & &1.to)
    middleware_by_hook = middlewares_by_hook(middlewares)

    hooks
    |> Enum.map(fn {hook, token} ->
      resolved = Map.get(resolved_by_hook, hook, [])
      chat_aliases = unique_sorted(resolved, & &1.chat_alias)
      messages = unique_sorted_many(resolved, & &1.messages)

      %{
        name: hook,
        token_fingerprint: HookToken.fingerprint(token),
        route_count: length(resolved),
        chat_aliases: chat_aliases,
        chat_count: length(chat_aliases),
        messages: messages,
        message_count: length(messages),
        middlewares: Map.get(middleware_by_hook, hook, []),
        push_count: Enum.count(resolved, & &1.push)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp middlewares_by_hook(middlewares) do
    middlewares
    |> Enum.flat_map(fn middleware ->
      Enum.map(middleware.routes, fn route -> {route.hook, middleware.name} end)
    end)
    |> Enum.group_by(fn {hook, _name} -> hook end, fn {_hook, name} -> name end)
    |> Map.new(fn {hook, names} -> {hook, unique_sorted(names, & &1)} end)
  end

  defp unique_sorted(items, mapper) do
    items
    |> Enum.map(mapper)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unique_sorted_many(items, mapper) do
    items
    |> Enum.flat_map(mapper)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
