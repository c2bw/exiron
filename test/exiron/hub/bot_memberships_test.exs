defmodule Exiron.Hub.BotMembershipsTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub.{
    ActivityState,
    BotLookupTasks,
    BotMemberships,
    Effect,
    LookupState,
    Telegram
  }

  alias Exiron.Secret

  @assert_timeout 1_000

  test "starts each lookup once per configuration generation" do
    dispatcher = start_supervised!({BotLookupTasks, name: nil})
    state = lookup_state()
    parent = self()

    opts =
      [
        bot_lookup_dispatcher: dispatcher,
        bot_membership_resolver: fn target ->
          send(parent, {:membership_target, target})
          {:ok, %{status: "member"}}
        end
      ]

    state = BotMemberships.start_lookups(state, opts)

    assert state.lookups.membership_keys == MapSet.new([{7, "secret-token"}])

    assert_receive {:membership_target, %{chat_id: 7, bot_token: "secret-token", bot_user_id: 9}},
                   @assert_timeout

    assert_receive {:bot_membership_lookup_complete, generation, token, 7,
                    {:ok, %{status: "member"}}},
                   @assert_timeout

    assert generation == state.lookups.generation
    assert Secret.reveal(token) == "secret-token"

    assert BotMemberships.start_lookups(state, opts) == state
    refute_receive {:membership_target, _target}, 50
  end

  test "refreshes existing membership metadata after identity resolution" do
    state = %{
      lookup_state()
      | telegram:
          Telegram.new([
            %{chat_id: 7, bot_token: "secret-token", bot_name: nil, bot_user_id: 9}
          ]),
        activity: %ActivityState{
          bot_memberships: %{
            {7, "secret-token"} => %{
              chat_id: 7,
              bot_name: nil,
              bot_user_id: 9,
              status: "member",
              present: true
            }
          }
        }
    }

    telegram =
      Telegram.put_bot_identity(state.telegram, "secret-token", %{
        bot_name: "helper",
        bot_user_id: 9
      })

    state =
      state |> Map.put(:telegram, telegram) |> BotMemberships.refresh_identity("secret-token")

    assert state.activity.bot_memberships[{7, "secret-token"}].bot_name == "helper"
  end

  test "prunes memberships that are no longer configured" do
    state = %State{
      telegram:
        Telegram.new([
          %{chat_id: 7, bot_token: "retained-token", bot_name: "helper"}
        ]),
      activity: %ActivityState{
        bot_memberships: %{
          {7, "retained-token"} => %{chat_id: 7, status: "member", present: true},
          {8, "removed-token"} => %{chat_id: 8, status: "member", present: true}
        }
      }
    }

    state = BotMemberships.prune_unconfigured(state)

    assert state.activity.bot_memberships == %{
             {7, "retained-token"} => %{chat_id: 7, status: "member", present: true}
           }
  end

  test "applies current lookup results and ignores stale generations" do
    state = lookup_state()

    transition =
      BotMemberships.complete_lookup(
        state,
        state.lookups.generation,
        Secret.new("secret-token"),
        7,
        {:ok, %{"status" => "administrator"}}
      )

    updated = transition.next_state

    assert [%Effect{kind: :broadcast_status}] = transition.effects

    assert updated.activity.bot_memberships[{7, "secret-token"}] == %{
             chat_id: 7,
             bot_name: "helper",
             bot_user_id: 9,
             status: "administrator",
             present: true
           }

    assert %{next_state: ^state, effects: []} =
             BotMemberships.complete_lookup(
               state,
               make_ref(),
               Secret.new("secret-token"),
               7,
               {:ok, %{status: "member"}}
             )
  end

  test "records terminal lookup failures without exposing the bot token" do
    state = lookup_state()

    transition =
      BotMemberships.complete_lookup(
        state,
        "secret-token",
        7,
        {:error, %ExGram.Error{code: 403, message: "Forbidden for secret-token"}}
      )

    updated = transition.next_state

    assert updated.activity.bot_memberships[{7, "secret-token"}] == %{
             chat_id: 7,
             bot_name: "helper",
             bot_user_id: 9,
             status: "unknown",
             present: false,
             error: "Forbidden for [REDACTED]"
           }
  end

  test "releases and retries transient membership lookup failures" do
    generation = make_ref()

    state = %{
      lookup_state()
      | lookups: %LookupState{
          generation: generation,
          membership_keys: MapSet.new([{7, "secret-token"}])
        }
    }

    transition =
      BotMemberships.complete_lookup(
        state,
        generation,
        Secret.new("secret-token"),
        7,
        {:error, :timeout},
        bot_lookup_retry_delay_ms: 1
      )

    updated = transition.next_state

    assert updated.lookups.membership_keys == MapSet.new()
    assert [%Effect{kind: :schedule, payload: {message, 1}}] = transition.effects
    assert {:retry_bot_membership_lookups, ^generation} = message

    parent = self()

    dispatcher = start_supervised!({BotLookupTasks, name: nil})

    opts = [
      bot_lookup_dispatcher: dispatcher,
      telegram_membership_lookups_enabled: true,
      bot_membership_resolver: fn target ->
        send(parent, {:membership_retried, target})
        {:ok, %{status: "member"}}
      end
    ]

    retried = BotMemberships.retry_lookups(updated, generation, opts)
    assert retried.lookups.membership_keys == MapSet.new([{7, "secret-token"}])
    assert_receive {:membership_retried, %{chat_id: 7, bot_token: "secret-token"}}
  end

  test "projects membership events into the current membership index" do
    event = %{
      chat_id: 7,
      bot_token: "token",
      bot_name: "helper",
      bot_user_id: 9,
      new_status: "member",
      action: "added"
    }

    state = BotMemberships.put_event(%State{}, event)

    assert state.activity.bot_memberships[{7, "token"}] == %{
             chat_id: 7,
             bot_name: "helper",
             bot_user_id: 9,
             status: "member",
             present: true
           }
  end

  test "ignores malformed membership events" do
    state = %State{}
    assert BotMemberships.put_event(state, %{chat_id: "7"}) == state
  end

  test "records a bounded public history without exposing the bot token" do
    existing_events = Enum.map(1..50, &%{id: &1})
    state = %State{activity: %ActivityState{membership_events: existing_events}}

    state =
      BotMemberships.record_event(state, %{
        chat_id: 7,
        bot_token: "secret-token",
        new_status: "member",
        action: "added"
      })

    assert [event | _events] = state.activity.membership_events
    assert length(state.activity.membership_events) == 50
    assert event.chat_id == 7
    assert %DateTime{} = event.at
    assert is_binary(event.id)
    refute Map.has_key?(event, :bot_token)

    assert state.activity.bot_memberships[{7, "secret-token"}].status == "member"
  end

  defp lookup_state do
    %State{
      telegram:
        Telegram.new([
          %{
            chat_id: 7,
            bot_token: "secret-token",
            bot_name: "helper",
            bot_user_id: 9
          }
        ]),
      lookups: %LookupState{generation: make_ref()}
    }
  end
end
