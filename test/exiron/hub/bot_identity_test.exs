defmodule Exiron.Hub.BotIdentityTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub.{BotIdentity, BotLookupTasks, Effect, LookupState, Router, Telegram}
  alias Exiron.Secret

  test "ignores identity results started by an older configuration" do
    state = state()

    transition =
      BotIdentity.complete_lookup(
        state,
        make_ref(),
        Secret.new("bot-token"),
        {:ok, "stale-name"}
      )

    assert %{next_state: ^state, effects: []} = transition
  end

  test "applies identity results from the current configuration" do
    state = state()

    transition =
      BotIdentity.complete_lookup(
        state,
        state.lookups.generation,
        Secret.new("bot-token"),
        {:ok, %{bot_name: nil, bot_user_id: 42}}
      )

    updated = transition.next_state

    assert [%Effect{kind: :broadcast_status}] = transition.effects
    assert [%{bot_user_id: 42}] = Telegram.bot_snapshots(updated.telegram)
  end

  test "keeps a configured poller name when identity lookup returns a different name" do
    parent = self()

    state = %{
      state()
      | telegram:
          Telegram.new(
            [
              %{chat_id: 123, bot_token: "bot-token", bot_name: "configured-name"},
              %{chat_id: 456, bot_token: "bot-token", bot_name: nil}
            ],
            poller_bot_name_updater: fn token, bot_name ->
              send(parent, {:poller_bot_name_updated, token, bot_name})
              :ok
            end
          )
    }

    transition =
      BotIdentity.complete_lookup(
        state,
        "bot-token",
        {:ok, %{bot_name: "resolved-name", bot_user_id: 42}}
      )

    updated = transition.next_state

    assert_receive {:poller_bot_name_updated, "bot-token", "configured-name"}
    assert [%{bot_name: "configured-name"}] = Telegram.bot_snapshots(updated.telegram)
  end

  test "retries transient identity lookup failures for the current configuration" do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    dispatcher =
      start_supervised!({BotLookupTasks, name: nil, task_supervisor: task_supervisor})

    state = %{state() | router: %Router{}}
    parent = self()

    transition =
      BotIdentity.complete_lookup(
        state,
        state.lookups.generation,
        Secret.new("bot-token"),
        {:error, :timeout},
        bot_lookup_retry_delay_ms: 1
      )

    assert transition.next_state == state
    assert [%Effect{kind: :schedule, payload: {message, 1}}] = transition.effects
    {:retry_bot_identity_lookup, generation, token} = message
    assert generation == state.lookups.generation
    assert Secret.reveal(token) == "bot-token"

    opts = [
      telegram_identity_lookups_enabled: true,
      bot_lookup_dispatcher: dispatcher,
      bot_identity_resolver: fn token ->
        send(parent, {:identity_retried, token, self()})

        receive do
          :resolve -> {:ok, %{bot_name: "helper", bot_user_id: 42}}
        end
      end
    ]

    assert BotIdentity.retry_lookup(state, generation, token, opts).next_state == state
    assert_receive {:identity_retried, "bot-token", worker}
    monitor = Process.monitor(worker)
    send(worker, :resolve)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    _ = :sys.get_state(dispatcher)
    assert_receive {:bot_identity_lookup_complete, ^generation, _token, {:ok, _identity}}
  end

  test "does not retry terminal identity lookup failures" do
    state = state()

    assert BotIdentity.complete_lookup(
             state,
             state.lookups.generation,
             Secret.new("bot-token"),
             {:error, %ExGram.Error{code: 401, message: "Unauthorized"}},
             bot_lookup_retry_delay_ms: 1
           ).next_state == state

    refute_receive {:retry_bot_identity_lookup, _generation, _token}, 10
  end

  defp state do
    %State{
      telegram: Telegram.new([%{chat_id: 123, bot_token: "bot-token"}]),
      lookups: %LookupState{generation: make_ref()},
      telegram_pollers_enabled?: false
    }
  end
end
