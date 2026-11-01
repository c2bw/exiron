defmodule Exiron.Hub.TelegramEvents do
  @moduledoc false

  alias Exiron.Hub.{BotIdentity, BotMemberships, Effect, PollerRegistry, State, Transition}
  alias Exiron.Secret

  @spec membership_changed(State.t(), map()) :: Transition.t()
  def membership_changed(state, event) do
    event = Map.update(event, :bot_token, nil, &Secret.reveal/1)

    state
    |> BotMemberships.record_event(event)
    |> Transition.new(reply: :ok, effects: [Effect.broadcast_status()])
  end

  @spec poller_started(State.t(), Secret.t(), pid(), DateTime.t()) :: Transition.t()
  def poller_started(state, token, pid, at) do
    token = Secret.reveal(token)
    already_tracked? = match?(%{pid: ^pid}, Map.get(state.telegram_pollers, token))

    state =
      state
      |> PollerRegistry.track(token, pid)
      |> Map.put(:telegram_last_polled_at, at)

    if already_tracked? do
      Transition.new(state)
    else
      Transition.new(state, effects: [Effect.broadcast_status()])
    end
  end

  @spec poller_stopped(State.t(), Secret.t(), pid()) :: Transition.t()
  def poller_stopped(state, token, pid) do
    state
    |> PollerRegistry.untrack(Secret.reveal(token), pid)
    |> Transition.new(effects: [Effect.broadcast_status()])
  end

  @spec poller_down(State.t(), reference(), pid()) :: Transition.t()
  def poller_down(state, monitor, pid) do
    case PollerRegistry.remove_down(state, monitor, pid) do
      {:unchanged, state} ->
        Transition.new(state)

      {:removed, state} ->
        Transition.new(state, effects: [Effect.broadcast_status()])
    end
  end

  @spec identity_lookup_complete(State.t(), reference(), String.t(), term()) :: Transition.t()
  def identity_lookup_complete(state, generation, token, result) do
    BotIdentity.complete_lookup(state, generation, token, result)
  end

  @spec retry_identity_lookup(State.t(), reference(), String.t()) :: Transition.t()
  def retry_identity_lookup(state, generation, token) do
    BotIdentity.retry_lookup(state, generation, token, state.runtime_options)
  end

  @spec membership_lookup_complete(State.t(), reference(), String.t(), integer(), term()) ::
          Transition.t()
  def membership_lookup_complete(state, generation, token, chat_id, result) do
    BotMemberships.complete_lookup(state, generation, token, chat_id, result)
  end

  @spec retry_membership_lookups(State.t(), reference()) :: Transition.t()
  def retry_membership_lookups(state, generation) do
    state
    |> BotMemberships.retry_lookups(generation, state.runtime_options)
    |> Transition.new()
  end
end
