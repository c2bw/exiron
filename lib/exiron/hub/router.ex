defmodule Exiron.Hub.Router do
  @moduledoc false

  alias Exiron.Hub.{HookToken, Message}
  alias Exiron.Hub.Router.{Builder, Validator}

  @telegram_service_id 222
  @addressed_command ~r{^/([A-Za-z0-9_]+)@[A-Za-z0-9_]+(?=\s|$)}

  @derive {Inspect, only: []}
  defstruct routes: [],
            routes_by_address: %{},
            routes_by_hook: %{},
            push_targets_by_hook: %{},
            listen_addresses_by_hook: %{},
            hooks: %{},
            bot_names: %{}

  def load(path) do
    with {:ok, definitions} <- YamlElixir.read_from_file(path),
         {:ok, router} <- load_definitions(definitions) do
      {:ok, router}
    end
  end

  def load_definitions(definitions) do
    with {:ok, %{routes: routes, hooks: hooks, bot_names: bot_names}} <-
           Builder.build(definitions) do
      {:ok,
       %__MODULE__{
         routes: routes,
         routes_by_address: routes_by_address(routes),
         routes_by_hook: Enum.group_by(routes, & &1.to),
         push_targets_by_hook: push_targets_by_hook(routes),
         listen_addresses_by_hook: listen_addresses_by_hook(routes),
         hooks: hooks,
         bot_names: bot_names
       }}
    end
  end

  def hook_for_token(%__MODULE__{hooks: hooks}, token) when is_binary(token) do
    incoming_digest = HookToken.raw_digest(token)

    Enum.find_value(hooks, fn {hook, configured_token} ->
      if HookToken.matches?(configured_token, incoming_digest, token), do: hook
    end)
  end

  def hooks(%__MODULE__{hooks: hooks}), do: Enum.sort(Map.keys(hooks))

  def bot_name(%__MODULE__{bot_names: bot_names}, bot_tag) when is_binary(bot_tag) do
    Map.get(bot_names, Validator.normalize_bot_tag(bot_tag), bot_tag)
  end

  def match_text(%__MODULE__{} = router, chat_id, text)
      when is_integer(chat_id) and is_binary(text) do
    match(router, Message.new(@telegram_service_id, chat_id, "text", text))
  end

  def match(%__MODULE__{routes_by_address: routes_by_address}, %Message{} = message) do
    texts = message |> Message.text() |> matching_texts()

    routes_by_address
    |> Map.get({message.service_id, message.chat_id}, [])
    |> matching_prefixes(texts)
    |> Enum.max_by(fn {_route, prefix} -> String.length(prefix) end, fn -> nil end)
    |> case do
      {route, _prefix} -> {:ok, route}
      nil -> :error
    end
  end

  def routed_message(
        %Message{datatype: "text", data: text} = message,
        %{passthrough: true} = route
      ) do
    %{message | data: routed_text(text, route), entities: nil}
  end

  def routed_message(%Message{caption: caption} = message, %{passthrough: true} = route)
      when is_binary(caption),
      do: %{message | caption: routed_text(caption, route), caption_entities: nil}

  def routed_message(%Message{} = message, _route), do: message

  def routed_text(text, %{passthrough: true, messages: prefixes})
      when is_binary(text) and is_list(prefixes) do
    text
    |> matching_texts()
    |> matching_prefix_remainders(prefixes)
    |> Enum.max_by(fn {prefix, _rest} -> String.length(prefix) end, fn -> nil end)
    |> case do
      {_prefix, rest} -> "/" <> String.trim_leading(rest)
      nil -> text
    end
  end

  def routed_text(text, _route) when is_binary(text), do: text

  def push_targets(%__MODULE__{} = router, hook) do
    router
    |> push_targets_for_hook(hook)
    |> Enum.map(&Map.take(&1, [:service_id, :chat_id, :default_bot]))
    |> Enum.uniq()
  end

  def push_targets(%__MODULE__{} = router, hook, chat_id) do
    router
    |> push_targets(hook)
    |> Enum.filter(&(&1.chat_id == chat_id))
  end

  def can_listen?(%__MODULE__{} = router, hook, %{service_id: service_id, chat_id: chat_id}) do
    router.listen_addresses_by_hook
    |> Map.get(hook, MapSet.new())
    |> MapSet.member?({service_id, chat_id})
  end

  def snapshot(%__MODULE__{routes: routes}), do: Enum.map(routes, &route_snapshot/1)

  def snapshot_for_hook(%__MODULE__{} = router, hook) do
    router
    |> routes_for_hook(hook)
    |> Enum.map(&route_snapshot/1)
  end

  defp routes_by_address(routes) do
    Enum.group_by(routes, &{&1.service_id, &1.chat_id})
  end

  defp push_targets_by_hook(routes) do
    routes
    |> Enum.filter(& &1.push)
    |> Enum.group_by(& &1.to)
  end

  defp listen_addresses_by_hook(routes) do
    Enum.reduce(routes, %{}, fn route, addresses_by_hook ->
      Map.update(
        addresses_by_hook,
        route.to,
        MapSet.new([{route.service_id, route.chat_id}]),
        &MapSet.put(&1, {route.service_id, route.chat_id})
      )
    end)
  end

  defp routes_for_hook(%__MODULE__{routes_by_hook: routes_by_hook}, hook),
    do: Map.get(routes_by_hook, hook, [])

  defp push_targets_for_hook(
         %__MODULE__{push_targets_by_hook: push_targets_by_hook},
         hook
       ) do
    Map.get(push_targets_by_hook, hook, [])
  end

  defp matching_prefixes(routes, texts) do
    for text <- texts,
        route <- routes,
        prefix <- route.messages,
        message_matches?(prefix, text),
        do: {route, prefix}
  end

  defp matching_prefix_remainders(texts, prefixes) do
    for text <- texts,
        prefix <- prefixes,
        {:ok, rest} <- [split_matching_prefix(prefix, text)],
        do: {prefix, rest}
  end

  # Prefixes match whole commands only: "/ai" matches "/ai hello" but not "/aiv".
  defp message_matches?(prefix, message) do
    match?({:ok, _rest}, split_matching_prefix(prefix, message))
  end

  defp split_matching_prefix(prefix, message) do
    case String.split_at(message, String.length(prefix)) do
      {^prefix, ""} ->
        {:ok, ""}

      {^prefix, rest} ->
        if Regex.match?(~r/^\s/u, rest), do: {:ok, rest}, else: :error

      _no_match ->
        :error
    end
  end

  defp matching_texts(text) do
    [text, normalize_addressed_command(text)]
    |> Enum.uniq()
  end

  defp normalize_addressed_command(text) do
    Regex.replace(@addressed_command, text, fn _match, command -> "/" <> command end,
      global: false
    )
  end

  defp route_snapshot(route) do
    %{
      id: route.id,
      service_id: route.service_id,
      chat_id: route.chat_id,
      chat_alias: route.chat_alias,
      to: route.to,
      messages: route.messages,
      passthrough: Map.get(route, :passthrough, false),
      push: route.push,
      default_bot: route.default_bot
    }
  end
end
