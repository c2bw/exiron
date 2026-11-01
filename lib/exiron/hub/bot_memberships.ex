defmodule Exiron.Hub.BotMemberships do
  @moduledoc false

  alias Exiron.Hub.{BotLookupTasks, Effect, History, Identifier, Telegram, Transition}
  alias Exiron.Secret

  @max_events 50
  @present_statuses ["creator", "administrator", "member", "restricted"]

  def maybe_start_lookups(state, opts) do
    if lookups_enabled?(state, opts), do: start_lookups(state, opts), else: state
  end

  def start_lookups(state, opts) do
    resolver = resolver(opts)
    generation = state.lookups.generation
    started_keys = state.lookups.membership_keys

    targets =
      state.telegram
      |> Telegram.membership_targets()
      |> Enum.uniq_by(&lookup_key/1)
      |> Enum.reject(&MapSet.member?(started_keys, lookup_key(&1)))

    :ok =
      BotLookupTasks.start(
        targets,
        resolver,
        fn target, result ->
          {:bot_membership_lookup_complete, generation, Secret.new(target.bot_token),
           target.chat_id, result}
        end,
        BotLookupTasks.dispatch_options(opts)
      )

    keys = Enum.reduce(targets, started_keys, &MapSet.put(&2, lookup_key(&1)))

    %{state | lookups: %{state.lookups | membership_keys: keys}}
  end

  def refresh_identity(state, token) do
    targets =
      state.telegram
      |> Telegram.membership_targets()
      |> Enum.filter(&(&1.bot_token == token))
      |> Map.new(&{lookup_key(&1), &1})

    memberships =
      Map.new(state.activity.bot_memberships, fn {key, membership} ->
        case Map.fetch(targets, key) do
          {:ok, target} ->
            identity = Map.take(target, [:bot_name, :bot_user_id])
            {key, Map.merge(membership, identity)}

          :error ->
            {key, membership}
        end
      end)

    %{state | activity: %{state.activity | bot_memberships: memberships}}
  end

  def prune_unconfigured(state) do
    configured_keys =
      state.telegram
      |> Telegram.configs()
      |> MapSet.new(&{&1.chat_id, &1.bot_token})

    memberships = Map.take(state.activity.bot_memberships, MapSet.to_list(configured_keys))
    %{state | activity: %{state.activity | bot_memberships: memberships}}
  end

  def complete_lookup(state, generation, token, chat_id, result) do
    complete_lookup(state, generation, token, chat_id, result, state.runtime_options)
  end

  def complete_lookup(state, generation, token, chat_id, result, opts) do
    if BotLookupTasks.current_generation?(state, generation) do
      token = Secret.reveal(token)

      case lookup_payload(state.telegram, token, chat_id, result) do
        nil ->
          if BotLookupTasks.retryable_result?(result) do
            state = release_lookup(state, token, chat_id)
            delay_ms = BotLookupTasks.retry_delay(opts)

            Transition.new(state,
              effects: [
                Effect.schedule({:retry_bot_membership_lookups, generation}, delay_ms)
              ]
            )
          else
            Transition.new(state)
          end

        payload ->
          put_lookup_payload(state, token, chat_id, payload)
      end
    else
      Transition.new(state)
    end
  end

  def complete_lookup(state, token, chat_id, result) do
    case lookup_payload(state.telegram, token, chat_id, result) do
      nil ->
        Transition.new(state)

      payload ->
        put_lookup_payload(state, token, chat_id, payload)
    end
  end

  def retry_lookups(state, generation, opts) do
    if BotLookupTasks.current_generation?(state, generation) do
      maybe_start_lookups(state, opts)
    else
      state
    end
  end

  def record_event(state, event) do
    event =
      event
      |> Map.put(:id, Identifier.new())
      |> Map.put(:at, DateTime.utc_now())

    state = put_event(state, event)
    public_event = Map.delete(event, :bot_token)

    activity = %{
      state.activity
      | membership_events:
          History.prepend(state.activity.membership_events, public_event, @max_events)
    }

    %{state | activity: activity}
  end

  def put_event(state, %{chat_id: chat_id, bot_token: token} = event)
      when is_integer(chat_id) and is_binary(token) do
    membership = %{
      chat_id: chat_id,
      bot_name: Map.get(event, :bot_name),
      bot_user_id: Map.get(event, :bot_user_id),
      status: Map.get(event, :new_status),
      present: Map.get(event, :action) == "added"
    }

    activity = %{
      state.activity
      | bot_memberships: Map.put(state.activity.bot_memberships, {chat_id, token}, membership)
    }

    %{state | activity: activity}
  end

  def put_event(state, _event), do: state

  defp lookups_enabled?(state, opts) do
    Keyword.get(opts, :telegram_membership_lookups_enabled, state.telegram_pollers_enabled?)
  end

  defp resolver(opts) do
    Keyword.get(opts, :bot_membership_resolver, &telegram_bot_membership/1)
  end

  defp telegram_bot_membership(target) do
    ExGram.get_chat_member(target.chat_id, target.bot_user_id, token: target.bot_token)
  end

  defp lookup_payload(telegram, token, chat_id, {:ok, member}) do
    case member_status(member) do
      status when is_binary(status) ->
        lookup_payload(telegram, token, chat_id, status, present?: status in @present_statuses)

      nil ->
        nil
    end
  end

  defp lookup_payload(telegram, token, chat_id, {:error, %ExGram.Error{code: code} = error})
       when code in [400, 401, 403] do
    telegram
    |> lookup_payload(token, chat_id, "unknown", present?: false)
    |> Map.put(:error, redact_token(error.message, token))
  end

  defp lookup_payload(_telegram, _token, _chat_id, _result), do: nil

  defp lookup_payload(telegram, token, chat_id, status, opts) do
    target = membership_target(telegram, token, chat_id)

    %{
      chat_id: chat_id,
      bot_name: target && target.bot_name,
      bot_user_id: target && target.bot_user_id,
      status: status,
      present: Keyword.fetch!(opts, :present?)
    }
  end

  defp membership_target(telegram, token, chat_id) do
    telegram
    |> Telegram.membership_targets()
    |> Enum.find(&(&1.bot_token == token and &1.chat_id == chat_id))
  end

  defp lookup_key(target), do: {target.chat_id, target.bot_token}

  defp release_lookup(state, token, chat_id) do
    %{
      state
      | lookups: %{
          state.lookups
          | membership_keys: MapSet.delete(state.lookups.membership_keys, {chat_id, token})
        }
    }
  end

  defp put_lookup_payload(state, token, chat_id, payload) do
    next_state = %{
      state
      | activity: %{
          state.activity
          | bot_memberships: Map.put(state.activity.bot_memberships, {chat_id, token}, payload)
        }
    }

    Transition.new(next_state, effects: [Effect.broadcast_status()])
  end

  defp member_status(%{status: status}) when is_binary(status), do: status
  defp member_status(%{"status" => status}) when is_binary(status), do: status
  defp member_status(_member), do: nil

  defp redact_token(message, token)
       when is_binary(message) and is_binary(token) and token != "",
       do: String.replace(message, token, "[REDACTED]")

  defp redact_token(message, _token), do: message
end
