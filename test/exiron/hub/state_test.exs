defmodule Exiron.Hub.StateTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{ActivityState, DeliveryState, LookupState, PublicationState, Settings, State}

  test "new builds the complete disabled state from defaults" do
    assert %State{
             enabled?: false,
             boot_failed?: false,
             telegram_pollers_enabled?: false,
             telegram_pollers: %{},
             router: nil,
             telegram: nil,
             settings: %Settings{},
             delivery: %DeliveryState{},
             activity: %ActivityState{},
             lookups: %LookupState{
               membership_keys: %MapSet{} = bot_membership_lookup_keys,
               incoming_message_keys: %MapSet{} = incoming_message_keys
             },
             publication: %PublicationState{}
           } = State.new()

    assert bot_membership_lookup_keys == MapSet.new()
    assert incoming_message_keys == MapSet.new()
  end

  test "new applies runtime attributes without dropping defaults" do
    router = make_ref()
    telegram = make_ref()

    assert %State{
             enabled?: true,
             router: ^router,
             telegram: ^telegram,
             settings: %Settings{client_timeout: 123, max_pending: 7},
             delivery: %DeliveryState{}
           } =
             State.new(
               enabled?: true,
               router: router,
               telegram: telegram,
               settings:
                 Settings.from_options(
                   client_timeout: 123,
                   max_pending: 7
                 )
             )
  end
end
