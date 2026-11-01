defmodule ExironWeb.ConfigLive.RouteTesting do
  @moduledoc false

  alias Exiron.Hub.Router

  def route_tester_options(config) do
    Enum.map(config.routes, fn route -> {"#{route.alias} (#{route.chat_id})", route.alias} end)
  end

  def route_tester_hook_options(config) do
    Enum.map(config.hooks, fn hook -> {hook.name, hook.name} end)
  end

  def route_tester_mode_options do
    [{"Incoming message", "incoming"}, {"Hook push", "push"}]
  end

  def route_tester_mode(%Phoenix.HTML.Form{} = form) do
    case Phoenix.HTML.Form.input_value(form, :mode) do
      "push" -> "push"
      _value -> "incoming"
    end
  end

  def route_tester_status_text(%{status: :match, route: route}), do: "Routes to #{route.to}"

  def route_tester_status_text(%{status: :push_match, targets: targets}),
    do: "Pushes to #{length(targets)}"

  def route_tester_status_text(%{status: :push_miss}), do: "No push targets"
  def route_tester_status_text(%{status: :miss}), do: "No route"
  def route_tester_status_text(_result), do: "Waiting"

  def route_tester_status_class(%{status: status}) when status in [:match, :push_match] do
    "shrink-0 rounded-full bg-emerald-500/10 px-2 py-1 text-xs font-medium text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-300"
  end

  def route_tester_status_class(%{status: status}) when status in [:miss, :push_miss] do
    "shrink-0 rounded-full bg-rose-500/10 px-2 py-1 text-xs font-medium text-rose-700 dark:bg-rose-400/15 dark:text-rose-300"
  end

  def route_tester_status_class(_result) do
    "shrink-0 rounded-full bg-base-200 px-2 py-1 text-xs font-medium text-base-content/55"
  end

  def route_tester_match?(%{status: :match, route: %{id: id}}, id), do: true

  def route_tester_match?(%{status: :push_match, targets: targets}, id) do
    Enum.any?(targets, &(&1.route_id == id))
  end

  def route_tester_match?(_result, _id), do: false

  def route_tester_params({:ok, %{routes: [%{alias: alias} | _routes], hooks: hooks}}) do
    %{
      "mode" => "incoming",
      "chat_alias" => alias,
      "hook" => first_hook_name(hooks),
      "message" => ""
    }
  end

  def route_tester_params(_route_configuration) do
    %{"mode" => "incoming", "chat_alias" => "", "hook" => "", "message" => ""}
  end

  def test_route({:ok, config}, attrs) do
    mode = attrs |> Map.get("mode", "incoming") |> to_string()
    chat_alias = attrs |> Map.get("chat_alias", "") |> to_string()
    hook = attrs |> Map.get("hook", "") |> to_string()
    message = attrs |> Map.get("message", "") |> to_string()

    test_route(config, mode, chat_alias, hook, String.trim(message))
  end

  def test_route(_route_configuration, _attrs), do: idle_route()

  defp test_route(config, "push", _chat_alias, "", _message) do
    case config.hooks do
      [%{name: hook} | _hooks] -> test_push(config, hook)
      [] -> idle_route()
    end
  end

  defp test_route(config, "push", _chat_alias, hook, _message), do: test_push(config, hook)
  defp test_route(_config, _mode, "", _hook, _message), do: idle_route()
  defp test_route(_config, _mode, _chat_alias, _hook, ""), do: idle_route()

  defp test_route(
         %{router: %Router{} = router, aliases: aliases},
         _mode,
         chat_alias,
         _hook,
         message
       ) do
    case Map.get(aliases, chat_alias) do
      chat_id when is_integer(chat_id) -> match_route(router, chat_id, message)
      _chat_id -> missed_route()
    end
  end

  defp test_push(%{router: %Router{} = router, resolved_routes: routes}, hook) do
    targets =
      router
      |> Router.push_targets(hook)
      |> Enum.flat_map(&push_target_routes(routes, hook, &1))

    if targets == [] do
      %{status: :push_miss, route: nil, targets: []}
    else
      %{status: :push_match, route: nil, targets: targets}
    end
  end

  defp push_target_routes(routes, hook, %{chat_id: chat_id}) do
    routes
    |> Enum.filter(&(&1.to == hook and &1.chat_id == chat_id and &1.push))
    |> Enum.map(fn route ->
      %{route_id: route.id, chat_alias: route.chat_alias, chat_id: route.chat_id}
    end)
  end

  defp first_hook_name([%{name: name} | _hooks]), do: name
  defp first_hook_name(_hooks), do: ""

  defp match_route(router, chat_id, message) do
    case Router.match_text(router, chat_id, message) do
      {:ok, route} -> %{status: :match, route: route}
      :error -> missed_route()
    end
  end

  defp idle_route, do: %{status: :idle, route: nil}
  defp missed_route, do: %{status: :miss, route: nil}
end
