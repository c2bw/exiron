defmodule Exiron.Hub.Telegram.AlbumBufferTest do
  use ExUnit.Case, async: true
  alias Exiron.Hub.Telegram.{AlbumBuffer, PollerState}

  test "collects across polls, ignores repeated updates and flushes after a quiet interval" do
    first = %{update_id: 10, message: %{media_group_id: "group"}}
    second = %{update_id: 11, message: %{media_group_id: "group"}}
    assert {:buffered, state} = AlbumBuffer.collect(%PollerState{group_albums: true}, [first], 0)
    assert {:buffered, state} = AlbumBuffer.collect(state, [first, second], 100)
    assert {:buffered, state} = AlbumBuffer.collect(state, [first, second], 300)
    assert {:ready, [^first, ^second], state} = AlbumBuffer.collect(state, [], 451)
    refute AlbumBuffer.pending?(state)
    assert state.album_started_at == nil
  end

  test "ordinary updates stay immediate and the maximum collection time is bounded" do
    single = %{update_id: 1, message: %{text: "hello"}}

    assert {:ready, [^single], _} =
             AlbumBuffer.collect(%PollerState{group_albums: true}, [single], 0)

    group = %{update_id: 2, message: %{media_group_id: "group"}}
    {:buffered, state} = AlbumBuffer.collect(%PollerState{group_albums: true}, [group], 0)
    {:buffered, state} = AlbumBuffer.collect(state, [%{group | update_id: 3}], 1000)
    assert {:ready, updates, _} = AlbumBuffer.collect(state, [%{group | update_id: 4}], 1501)
    assert length(updates) == 3
  end
end
