defmodule ExironWeb.StatusStreams do
  @moduledoc false

  import Phoenix.LiveView, only: [stream: 4, stream_delete: 3, stream_insert: 4]

  def apply_delta(socket, name, %{reset: items}) do
    stream(socket, name, items, reset: true)
  end

  def apply_delta(socket, name, delta) do
    socket = Enum.reduce(delta.deletes, socket, &stream_delete(&2, name, &1))

    Enum.reduce(delta.upserts, socket, fn %{item: item, at: at}, socket ->
      stream_insert(socket, name, item, at: at)
    end)
  end
end
