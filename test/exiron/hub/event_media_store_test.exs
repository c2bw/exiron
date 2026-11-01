defmodule Exiron.Hub.EventMediaStoreTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.EventMediaStore

  test "evicts oldest media deterministically at the byte budget" do
    store = start_store!(5)

    assert {:ok, first} = EventMediaStore.put(store, "abc", "image/png", {:hook, "assistant"})
    assert {:ok, second} = EventMediaStore.put(store, "de", "image/png", {:hook, "assistant"})
    assert {:ok, %{bytes: "abc"}} = EventMediaStore.fetch(store, first, :dashboard)

    assert {:ok, third} = EventMediaStore.put(store, "xy", "image/png", {:hook, "assistant"})
    assert EventMediaStore.fetch(store, first, :dashboard) == {:error, :not_found}
    assert {:ok, %{bytes: "de"}} = EventMediaStore.fetch(store, second, :dashboard)
    assert {:ok, %{bytes: "xy"}} = EventMediaStore.fetch(store, third, :dashboard)
  end

  test "enforces scope authorization independently of opaque ids" do
    store = start_store!(100)
    assert {:ok, id} = EventMediaStore.put(store, "bytes", "image/jpeg", {:hook, "assistant"})

    assert {:ok, %{mime_type: "image/jpeg", bytes: "bytes"}} =
             EventMediaStore.fetch(store, id, {:hook, "assistant"})

    assert EventMediaStore.fetch(store, id, {:hook, "other"}) == {:error, :not_found}
    assert {:ok, %{bytes: "bytes"}} = EventMediaStore.fetch(store, id, :dashboard)
    assert EventMediaStore.fetch(store, "missing", :dashboard) == {:error, :not_found}
  end

  test "does not retain a media item larger than the configured budget" do
    store = start_store!(2)

    assert EventMediaStore.put(store, "abc", "image/png", nil) == {:error, :too_large}
  end

  test "deletes media explicitly and releases its byte budget" do
    store = start_store!(3)
    assert {:ok, first} = EventMediaStore.put(store, "abc", "image/png", nil)
    assert :ok = EventMediaStore.delete(store, first)
    assert EventMediaStore.fetch(store, first, :dashboard) == {:error, :not_found}

    assert {:ok, second} = EventMediaStore.put(store, "xyz", "image/png", nil)
    assert {:ok, %{bytes: "xyz"}} = EventMediaStore.fetch(store, second, :dashboard)
  end

  defp start_store!(max_bytes) do
    name = :"event_media_store_#{System.unique_integer([:positive])}"
    start_supervised!({EventMediaStore, name: name, max_bytes: max_bytes})
    name
  end
end
