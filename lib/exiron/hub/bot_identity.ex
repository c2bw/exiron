defmodule Exiron.Hub.BotIdentity do
  @moduledoc false

  alias Exiron.Hub.{BotLookupTasks, BotMemberships, Effect, Router, Telegram, Transition}
  alias Exiron.Secret

  def start_lookups(state, opts) do
    state =
      if lookups_enabled?(state, opts) do
        start_identity_lookups(state, Telegram.missing_identity_tokens(state.telegram), opts)
      else
        state
      end

    BotMemberships.maybe_start_lookups(state, opts)
  end

  def complete_lookup(state, generation, token, result) do
    complete_lookup(state, generation, token, result, state.runtime_options)
  end

  def complete_lookup(state, generation, token, result, opts) do
    if BotLookupTasks.current_generation?(state, generation) do
      token = Secret.reveal(token)

      if BotLookupTasks.retryable_result?(result) and missing_identity?(state, token) do
        delay_ms = BotLookupTasks.retry_delay(opts)

        Transition.new(state,
          effects: [
            Effect.schedule(
              {:retry_bot_identity_lookup, generation, Secret.new(token)},
              delay_ms
            )
          ]
        )
      else
        complete_lookup(state, token, result)
      end
    else
      Transition.new(state)
    end
  end

  def complete_lookup(state, token, result) do
    apply_lookup_result(state, token, result)
  end

  def retry_lookup(state, generation, token, opts) do
    token = Secret.reveal(token)

    state =
      if BotLookupTasks.current_generation?(state, generation) and
           lookups_enabled?(state, opts) and missing_identity?(state, token) do
        start_identity_lookups(state, [token], opts)
      else
        state
      end

    Transition.new(state)
  end

  defp apply_lookup_result(state, token, {:ok, %{bot_name: _bot_name} = identity}) do
    telegram = Telegram.put_bot_identity(state.telegram, token, identity)
    :ok = update_poller_bot_name(telegram, token)

    state =
      state
      |> Map.put(:telegram, telegram)
      |> BotMemberships.refresh_identity(token)
      |> BotMemberships.maybe_start_lookups(state.runtime_options)

    Transition.new(state, effects: [Effect.broadcast_status()])
  end

  defp apply_lookup_result(state, token, {:ok, bot_name})
       when is_binary(bot_name) and bot_name != "" do
    telegram = Telegram.put_bot_name(state.telegram, token, bot_name)
    :ok = update_poller_bot_name(telegram, token)

    state = state |> Map.put(:telegram, telegram) |> BotMemberships.refresh_identity(token)

    Transition.new(state, effects: [Effect.broadcast_status()])
  end

  defp apply_lookup_result(state, _token, _result), do: Transition.new(state)

  defp start_identity_lookups(state, tokens, opts) do
    resolver = resolver(state.router, opts)
    generation = state.lookups.generation

    BotLookupTasks.start(
      tokens,
      resolver,
      fn token, result ->
        {:bot_identity_lookup_complete, generation, Secret.new(token), result}
      end,
      BotLookupTasks.dispatch_options(opts)
    )

    state
  end

  defp missing_identity?(state, token),
    do: token in Telegram.missing_identity_tokens(state.telegram)

  defp lookups_enabled?(state, opts) do
    Keyword.get(opts, :telegram_identity_lookups_enabled, state.telegram_pollers_enabled?)
  end

  defp resolver(router, opts) do
    Keyword.get(
      opts,
      :bot_identity_resolver,
      Keyword.get(opts, :bot_name_resolver, &telegram_bot_identity(router, &1))
    )
  end

  defp telegram_bot_identity(router, token) do
    case ExGram.get_me(token: token) do
      {:ok, %{id: bot_user_id, username: username}} when is_integer(bot_user_id) ->
        {:ok, %{bot_user_id: bot_user_id, bot_name: resolved_bot_name(router, username)}}

      {:ok, %{username: username}} ->
        {:ok, %{bot_name: resolved_bot_name(router, username)}}

      {:ok, %{id: bot_user_id}} when is_integer(bot_user_id) ->
        {:ok, %{bot_user_id: bot_user_id}}

      {:ok, _bot} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolved_bot_name(_router, username) when username in [nil, ""], do: nil

  defp resolved_bot_name(router, username) when is_binary(username),
    do: Router.bot_name(router, username)

  defp maybe_update_poller_bot_name(_telegram, _token, bot_name) when bot_name in [nil, ""],
    do: :ok

  defp maybe_update_poller_bot_name(telegram, token, bot_name),
    do: Telegram.update_poller_bot_name(telegram, token, bot_name)

  defp update_poller_bot_name(telegram, token) do
    bot_name = Telegram.poller_bot_name(telegram, token)
    maybe_update_poller_bot_name(telegram, token, bot_name)
  end
end
