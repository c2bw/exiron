defmodule Exiron.Hub.StatusDelta do
  @moduledoc false

  @collection_keys [
    :hooks,
    :routes,
    :chats,
    :events,
    :send_failures,
    :overload_events,
    :membership_events,
    :bot_memberships,
    :client_events,
    :suppressed_bots
  ]

  @spec collection_keys() :: [atom()]
  def collection_keys, do: @collection_keys

  @spec between(map(), map()) :: :unchanged | {:changed, map()}
  def between(previous, current) do
    values = changed_values(previous, current)
    collections = changed_collections(previous, current)

    if values == %{} and collections == %{} do
      :unchanged
    else
      {:changed,
       %{
         values: values,
         collections: collections,
         metrics: metrics(current)
       }}
    end
  end

  defp changed_values(previous, current) do
    current
    |> Map.drop(@collection_keys ++ [:revision])
    |> Enum.reduce(%{}, fn {key, value}, changed ->
      if Map.get(previous, key) == value, do: changed, else: Map.put(changed, key, value)
    end)
  end

  defp changed_collections(previous, current) do
    Enum.reduce(@collection_keys, %{}, fn key, changed ->
      previous_items = Map.get(previous, key, [])
      current_items = Map.get(current, key, [])

      if previous_items == current_items do
        changed
      else
        Map.put(changed, key, collection_delta(key, previous_items, current_items))
      end
    end)
  end

  defp collection_delta(key, previous, current) do
    previous_by_id = Map.new(previous, &{identity(key, &1), &1})
    current_by_id = Map.new(current, &{identity(key, &1), &1})

    retained =
      Map.keys(previous_by_id)
      |> MapSet.new()
      |> MapSet.intersection(Map.keys(current_by_id) |> MapSet.new())

    previous_order =
      previous |> Enum.map(&identity(key, &1)) |> Enum.filter(&MapSet.member?(retained, &1))

    current_order =
      current |> Enum.map(&identity(key, &1)) |> Enum.filter(&MapSet.member?(retained, &1))

    if previous_order != current_order do
      %{count: length(current), reset: current}
    else
      deletes = Enum.reject(previous, &Map.has_key?(current_by_id, identity(key, &1)))

      upserts =
        current
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, index} ->
          id = identity(key, item)

          if Map.get(previous_by_id, id) == item do
            []
          else
            [%{item: item, at: index}]
          end
        end)

      %{count: length(current), deletes: deletes, upserts: upserts}
    end
  end

  defp identity(:hooks, item), do: Map.fetch!(item, :name)

  defp identity(:bot_memberships, item) do
    {Map.get(item, :chat_id), Map.get(item, :bot_user_id), Map.get(item, :bot_name)}
  end

  defp identity(_key, item), do: Map.fetch!(item, :id)

  defp metrics(status) do
    hooks = Map.get(status, :hooks, [])

    %{
      connected: Enum.count(hooks, & &1.connected),
      queued: Enum.sum_by(hooks, & &1.queued)
    }
  end
end
