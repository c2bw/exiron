defmodule Exiron.Hub.MediaAlbum do
  @moduledoc false
  alias Exiron.Hub.MessageMetadata

  @types ["image", "video", "audio", "file"]
  def decode(data, minimum \\ 2)

  def decode(data, minimum) when is_binary(data) do
    with {:ok, items} when is_list(items) <- Jason.decode(data),
         true <- length(items) in minimum..10,
         {:ok, items} <- decode_items(items),
         true <- compatible?(items) do
      {:ok, items}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  def decode(_, _), do: {:error, :invalid_payload}

  def encode(items) do
    items
    |> Enum.map(fn item -> Map.update!(item, :data, &Base.encode64/1) end)
    |> Jason.encode!()
  end

  defp decode_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn
      %{"datatype" => type, "data" => data} = item, {:ok, acc}
      when type in @types and is_binary(data) ->
        opts =
          Enum.flat_map(MessageMetadata.fields() ++ [:message_id, :parse_mode], fn key ->
            if Map.has_key?(item, Atom.to_string(key)),
              do: [{key, item[Atom.to_string(key)]}],
              else: []
          end)

        with {:ok, bytes} <- Base.decode64(data),
             :ok <- MessageMetadata.validate(type, bytes, opts) do
          {:cont, {:ok, [Map.merge(Map.new(opts), %{datatype: type, data: bytes}) | acc]}}
        else
          _ -> {:halt, {:error, :invalid_payload}}
        end

      _, _ ->
        {:halt, {:error, :invalid_payload}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp compatible?(items) do
    types = MapSet.new(items, & &1.datatype)
    MapSet.subset?(types, MapSet.new(["image", "video"])) or MapSet.size(types) == 1
  end
end
