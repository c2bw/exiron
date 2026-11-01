defmodule Exiron.Hub.QueueBufferTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Message, QueueBuffer}

  test "stores FIFO metrics while retaining newest-first internals" do
    first = message("first")
    second = message("second")

    {buffer, 0} = QueueBuffer.push(QueueBuffer.new(), first, {10, 100})
    {buffer, 0} = QueueBuffer.push(buffer, second, {10, 100})

    assert buffer.items == [second, first]
    assert buffer.count == 2

    assert buffer.bytes ==
             Message.client_payload_size(first) + Message.client_payload_size(second)

    assert QueueBuffer.drain(buffer) == {[first, second], QueueBuffer.new()}
  end

  test "keeps newest messages within both count and byte limits" do
    oldest = message("old")
    middle = message("middle")
    newest = message("newest")
    max_bytes = QueueBuffer.bytes([newest, middle])

    buffer = QueueBuffer.from_items([middle, oldest])

    assert {%QueueBuffer{items: [^newest, ^middle]}, 1} =
             QueueBuffer.push(buffer, newest, {3, max_bytes})
  end

  test "prepends recovered items ahead of newer queued items" do
    recovered_first = message("recovered-first")
    recovered_second = message("recovered-second")
    newer = message("newer")

    buffer =
      [newer]
      |> QueueBuffer.from_items()
      |> QueueBuffer.prepend([recovered_first, recovered_second])

    assert QueueBuffer.drain(buffer) ==
             {[recovered_first, recovered_second, newer], QueueBuffer.new()}
  end

  test "reports every dropped item when no capacity remains" do
    queued = message("queued")
    incoming = message("incoming")
    buffer = QueueBuffer.from_items([queued])
    assert {%QueueBuffer{items: []}, 2} = QueueBuffer.push(buffer, incoming, {0, 0})
  end

  defp message(data), do: Message.new("telegram", 7, "text", data)
end
