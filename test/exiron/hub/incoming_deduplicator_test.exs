defmodule Exiron.Hub.IncomingDeduplicatorTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub.{IncomingDeduplicator, Message}

  test "recognizes repeated service message identities" do
    message = message(42)

    assert {:new, state} = IncomingDeduplicator.remember(%State{}, message)
    assert {:duplicate, ^state} = IncomingDeduplicator.remember(state, message)
  end

  test "messages without an id are not deduplicated" do
    state = %State{}
    assert {:new, ^state} = IncomingDeduplicator.remember(state, message(nil))
  end

  test "bounds retained identities and evicts the oldest" do
    state =
      Enum.reduce(1..501, %State{}, fn id, state ->
        assert {:new, state} = IncomingDeduplicator.remember(state, message(id))
        state
      end)

    assert MapSet.size(state.lookups.incoming_message_keys) == 500
    assert {:new, _state} = IncomingDeduplicator.remember(state, message(1))
    assert {:duplicate, ^state} = IncomingDeduplicator.remember(state, message(501))
  end

  defp message(message_id) do
    %Message{service_id: "telegram", chat_id: 7, message_id: message_id}
  end
end
