defmodule Exiron.Hub.Router.Builder do
  @moduledoc false

  alias Exiron.Hub.Router.Validator

  @telegram_service_id 222

  def build(definitions) do
    with {:ok, validated} <- Validator.validate(definitions),
         %{definitions: definitions, hooks: hooks, bot_names: bot_names} = validated,
         {:ok, routes} <- create_routes(definitions) do
      {:ok, %{routes: routes, hooks: hooks, bot_names: bot_names}}
    end
  end

  defp create_routes(definitions) do
    {:ok, definitions |> sections() |> build_routes() |> finalize_routes()}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp sections(definitions) do
    Exiron.Hub.AccessPolicy.validate_schema!(definitions)

    %{
      aliases:
        definitions |> get_in(["aliases", "telegram"]) |> map_or_empty!("aliases.telegram"),
      routes: definitions |> Map.get("routes") |> map_or_empty!("routes"),
      middlewares: definitions |> Map.get("middlewares") |> map_or_empty!("middlewares"),
      hooks: definitions |> Map.get("hooks") |> map_or_empty!("hooks")
    }
  end

  defp build_routes(%{routes: route_defs} = sections) do
    Enum.flat_map(route_defs, fn {alias, route_def} ->
      route_def = map!(route_def, "routes.#{alias}")

      route_context = %{
        alias: alias,
        chat_id: fetch_alias!(sections.aliases, alias),
        middleware_names:
          list_or_empty!(Map.get(route_def, "middleware"), "routes.#{alias}.middleware"),
        push: boolean!("routes.#{alias}.push", Map.get(route_def, "push", false)),
        default_bot:
          optional_string!("routes.#{alias}.default_bot", Map.get(route_def, "default_bot"))
      }

      build_routes_for_alias(route_context, sections)
    end)
  end

  defp build_routes_for_alias(route_context, sections) do
    Enum.flat_map(route_context.middleware_names, fn middleware_name ->
      middleware = fetch_middleware!(sections.middlewares, middleware_name)
      route_entries = middleware_route_entries!(middleware, middleware_name)

      Enum.map(route_entries, fn {hook_name, requirements} ->
        build_route(route_context, middleware_name, hook_name, requirements, sections.hooks)
      end)
    end)
  end

  defp middleware_route_entries!(middleware, middleware_name) do
    middleware
    |> Map.get("routes")
    |> map_or_empty!("middlewares.#{middleware_name}.routes")
  end

  defp build_route(route_context, middleware_name, hook_name, requirements, hooks) do
    unless Map.has_key?(hooks, hook_name) do
      raise ArgumentError, "hook does not exist: #{hook_name}"
    end

    %{
      service_id: @telegram_service_id,
      chat_id: route_context.chat_id,
      chat_alias: route_context.alias,
      to: hook_name,
      messages: route_messages!(requirements, middleware_name, hook_name),
      passthrough: route_passthrough!(requirements, middleware_name, hook_name),
      push: route_context.push,
      default_bot: route_context.default_bot
    }
    |> Exiron.Hub.InteractionPolicy.attach(Map.get(requirements, "interaction"))
  end

  defp route_messages!(requirements, middleware_name, hook_name) do
    path = "middlewares.#{middleware_name}.routes.#{hook_name}"

    messages =
      requirements
      |> map!(path)
      |> Map.get("messages")
      |> list_or_empty!("#{path}.messages")
      |> Enum.map(fn message -> message |> string!() |> String.trim() end)
      |> Enum.reject(&(&1 == ""))
      |> unique_longest_first()

    if messages == [], do: raise(ArgumentError, "route for #{hook_name} has no messages")

    messages
  end

  defp route_passthrough!(requirements, middleware_name, hook_name) do
    path = "middlewares.#{middleware_name}.routes.#{hook_name}"

    requirements
    |> map!(path)
    |> Map.get("passthrough", false)
    |> then(&boolean!("#{path}.passthrough", &1))
  end

  defp fetch_alias!(aliases, alias) do
    case Map.fetch(aliases, alias) do
      {:ok, chat_id} when is_integer(chat_id) ->
        chat_id

      {:ok, _chat_id} ->
        raise ArgumentError, "aliases.telegram.#{alias} must be an integer"

      :error ->
        raise ArgumentError, "missing telegram alias: #{alias}"
    end
  end

  defp fetch_middleware!(middlewares, name) do
    case Map.fetch(middlewares, name) do
      {:ok, middleware} -> map!(middleware, "middlewares.#{name}")
      :error -> raise ArgumentError, "middleware does not exist: #{name}"
    end
  end

  defp map_or_empty!(nil, _path), do: %{}
  defp map_or_empty!(value, path), do: map!(value, path)

  defp list_or_empty!(nil, _path), do: []
  defp list_or_empty!(value, _path) when is_list(value), do: value
  defp list_or_empty!(_value, path), do: raise(ArgumentError, "#{path} must be a list")

  defp map!(value, _path) when is_map(value), do: value
  defp map!(_value, path), do: raise(ArgumentError, "#{path} must be a map")

  defp boolean!(_path, value) when is_boolean(value), do: value
  defp boolean!(path, _value), do: raise(ArgumentError, "#{path} must be a boolean")

  defp optional_string!(_path, nil), do: nil

  defp optional_string!(path, value) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{path} must be a non-empty string"
      string -> string
    end
  end

  defp optional_string!(path, _value), do: raise(ArgumentError, "#{path} must be a string")

  defp string!(value) when is_binary(value), do: value
  defp string!(_value), do: raise(ArgumentError, "route messages must be strings")

  # Middlewares can contribute the same hook/chat route more than once. Collapse those
  # definitions before assigning stable ids so snapshots stay compact and predictable.
  defp merge_routes(routes) do
    routes
    |> Enum.group_by(
      &{&1.service_id, &1.chat_id, &1.chat_alias, &1.to, &1.push, &1.default_bot, &1.passthrough,
       Map.get(&1, :interaction, %{})}
    )
    |> Enum.map(fn {_key, grouped} ->
      grouped
      |> hd()
      |> Map.put(
        :messages,
        grouped
        |> Enum.flat_map(& &1.messages)
        |> unique_longest_first()
      )
    end)
  end

  defp finalize_routes(routes) do
    Exiron.Hub.AccessPolicy.validate_consistent!(routes)

    routes
    |> merge_routes()
    |> validate_unambiguous!()
    |> Enum.sort_by(
      &{&1.service_id, &1.chat_id, &1.chat_alias, &1.to, &1.passthrough, &1.messages,
       Map.get(&1, :interaction, %{})}
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {route, id} -> Map.put(route, :id, id) end)
  end

  defp unique_longest_first(messages) do
    messages
    |> Enum.uniq()
    |> Enum.sort_by(&String.length/1, :desc)
  end

  # A prefix may appear in many chats, but within a chat it must point to one hook.
  # Otherwise the router could not choose a destination deterministically.
  defp validate_unambiguous!(routes) do
    routes
    |> Enum.reduce(%{}, fn route, seen ->
      Enum.reduce(route.messages, seen, fn prefix, acc ->
        key = {route.service_id, route.chat_id, prefix}
        policy = Map.get(route, :interaction, %{})

        case Map.fetch(acc, key) do
          {:ok, %{to: destination}} when destination != route.to ->
            raise ArgumentError,
                  "message prefix #{inspect(prefix)} routes to both #{inspect(destination)} and #{inspect(route.to)}"

          {:ok, %{to: destination, passthrough: passthrough}}
          when passthrough != route.passthrough ->
            raise ArgumentError,
                  "message prefix #{inspect(prefix)} for #{inspect(destination)} has conflicting passthrough settings"

          {:ok, %{interaction: previous}} when previous != policy ->
            raise ArgumentError, "message prefix has conflicting interaction settings"

          _ ->
            Map.put(acc, key, %{
              to: route.to,
              passthrough: route.passthrough,
              interaction: Map.get(route, :interaction, %{})
            })
        end
      end)
    end)

    routes
  end
end
