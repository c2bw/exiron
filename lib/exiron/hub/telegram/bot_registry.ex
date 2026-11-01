defmodule Exiron.Hub.Telegram.BotRegistry do
  @moduledoc false

  alias Exiron.Hub.BotName

  @derive {Inspect, only: []}
  defstruct configs: [],
            default_by_chat: %{},
            token_by_chat: %{},
            config_by_chat_token: %{},
            bot_by_chat_name: %{},
            alternate_by_chat: %{},
            poller_by_token: %{}

  def new(configs) do
    build_registry(configs)
  end

  def configs(%__MODULE__{configs: configs}), do: configs

  def poller_bots(%__MODULE__{poller_by_token: poller_by_token} = registry) do
    Enum.map(poller_tokens(registry), &Map.fetch!(poller_by_token, &1))
  end

  def poller_tokens(%__MODULE__{configs: configs}), do: unique_tokens(configs)

  def poller_bot_name(%__MODULE__{poller_by_token: poller_by_token}, token)
      when is_binary(token),
      do: poller_by_token |> Map.get(token, %{}) |> Map.get(:name)

  def snapshots(registry) do
    Enum.map(poller_bots(registry), fn %{token: token, name: name, user_id: user_id} ->
      %{
        token_fingerprint: token_fingerprint(token),
        bot_name: name,
        bot_tag: bot_tag(name),
        bot_user_id: user_id
      }
    end)
  end

  def missing_identity_tokens(%__MODULE__{configs: configs}) do
    configs
    |> Enum.filter(
      &(Map.get(&1, :bot_name) in [nil, ""] or not is_integer(Map.get(&1, :bot_user_id)))
    )
    |> unique_tokens()
  end

  def missing_bot_name_tokens(%__MODULE__{configs: configs}) do
    configs
    |> Enum.filter(&(Map.get(&1, :bot_name) in [nil, ""]))
    |> unique_tokens()
  end

  def put_identity(%__MODULE__{} = registry, token, identity) when is_binary(token) do
    configs =
      Enum.map(registry.configs, fn
        %{bot_token: ^token} = config ->
          config
          |> maybe_put_bot_name(Map.get(identity, :bot_name))
          |> maybe_put_bot_user_id(Map.get(identity, :bot_user_id))

        config ->
          config
      end)

    build_registry(configs)
  end

  def put_identity(%__MODULE__{} = registry, _token, _identity), do: registry

  def membership_targets(%__MODULE__{configs: configs}) do
    configs
    |> Enum.filter(&(is_integer(Map.get(&1, :chat_id)) and is_integer(Map.get(&1, :bot_user_id))))
    |> Enum.map(fn config ->
      %{
        chat_id: config.chat_id,
        bot_token: config.bot_token,
        bot_name: Map.get(config, :bot_name),
        bot_user_id: config.bot_user_id
      }
    end)
    |> Enum.uniq()
  end

  def bot_for_name(%__MODULE__{bot_by_chat_name: bot_by_chat_name}, chat_id, bot_name)
      when is_integer(chat_id) and is_binary(bot_name) do
    normalized = BotName.normalize(bot_name)

    case Map.get(bot_by_chat_name, {chat_id, normalized}) do
      %{bot_token: token, bot_name: name} -> {:ok, %{token: token, name: name}}
      nil -> {:error, :telegram_bot_not_configured}
    end
  end

  def bot_for_name(_registry, _chat_id, _bot_name),
    do: {:error, :telegram_bot_not_configured}

  def default_bot_name(%__MODULE__{} = registry, chat_id) when is_integer(chat_id) do
    with {:ok, token} <- default_token(registry, chat_id),
         %{bot_name: bot_name} <- config_for(registry, chat_id, token),
         true <- is_binary(bot_name) and bot_name != "" do
      bot_name
    else
      _missing -> nil
    end
  end

  def default_bot_name(_registry, _chat_id), do: nil

  def configured_token?(%__MODULE__{token_by_chat: tokens}, chat_id, token) do
    Map.has_key?(tokens, {chat_id, token})
  end

  def default_token(%__MODULE__{default_by_chat: defaults}, chat_id),
    do: Map.fetch(defaults, chat_id)

  def alternate_tokens(%__MODULE__{alternate_by_chat: alternate_by_chat}, chat_id, default_token) do
    alternate_by_chat
    |> Map.get(chat_id, [])
    |> Enum.filter(&(&1 != default_token))
  end

  def config_for(%__MODULE__{config_by_chat_token: config_by_chat_token}, chat_id, token) do
    Map.get(config_by_chat_token, {chat_id, token})
  end

  def bot_tag(nil), do: nil

  def bot_tag(bot_name) when is_binary(bot_name) do
    bot_name
    |> BotName.normalize()
    |> case do
      "" -> nil
      tag -> "@" <> tag
    end
  end

  def token_fingerprint(token) when is_binary(token) do
    if String.length(token) <= 10 do
      String.duplicate("*", String.length(token))
    else
      "#{String.slice(token, 0, 6)}...#{String.slice(token, -4, 4)}"
    end
  end

  defp build_registry(configs) do
    %__MODULE__{
      configs: configs,
      default_by_chat: configs |> Enum.reverse() |> Map.new(&{&1.chat_id, &1.bot_token}),
      token_by_chat: Map.new(configs, &{{&1.chat_id, &1.bot_token}, &1.bot_token}),
      config_by_chat_token: first_config_by_chat_token(configs),
      bot_by_chat_name: first_bot_by_chat_name(configs),
      alternate_by_chat: alternate_by_chat(configs),
      poller_by_token: poller_by_token(configs)
    }
  end

  defp first_config_by_chat_token(configs) do
    configs
    |> Enum.reverse()
    |> Map.new(&{{&1.chat_id, &1.bot_token}, &1})
  end

  defp first_bot_by_chat_name(configs) do
    configs
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn config, index ->
      case BotName.normalize(Map.get(config, :bot_name)) do
        normalized when is_binary(normalized) ->
          Map.put(index, {config.chat_id, normalized}, config)

        _missing ->
          index
      end
    end)
  end

  defp alternate_by_chat(configs) do
    Enum.reduce(configs, %{}, fn config, index ->
      Map.update(index, config.chat_id, [config.bot_token], &[config.bot_token | &1])
    end)
    |> Map.new(fn {chat_id, tokens} -> {chat_id, Enum.reverse(tokens)} end)
  end

  defp poller_by_token(configs) do
    configs
    |> Enum.group_by(& &1.bot_token)
    |> Map.new(fn {token, grouped} ->
      {token,
       %{
         token: token,
         name: first_value(grouped, :bot_name),
         user_id: first_value(grouped, :bot_user_id)
       }}
    end)
  end

  defp unique_tokens(configs), do: configs |> Enum.map(& &1.bot_token) |> Enum.uniq()

  defp first_value(configs, key), do: Enum.find_value(configs, &Map.get(&1, key))

  defp maybe_put_bot_name(config, bot_name) when is_binary(bot_name) and bot_name != "" do
    case Map.get(config, :bot_name) do
      configured_name when is_binary(configured_name) and configured_name != "" -> config
      _missing -> Map.put(config, :bot_name, bot_name)
    end
  end

  defp maybe_put_bot_name(config, _bot_name), do: config

  defp maybe_put_bot_user_id(config, bot_user_id) when is_integer(bot_user_id) do
    Map.put(config, :bot_user_id, bot_user_id)
  end

  defp maybe_put_bot_user_id(config, _bot_user_id), do: config
end
