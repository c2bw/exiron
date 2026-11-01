defmodule ExironClient.MediaItem do
  @moduledoc "One album member. Data contains decoded file bytes."
  alias ExironClient.{Error, Wire}

  @fields [
    :datatype,
    :data,
    :caption,
    :parse_mode,
    :caption_entities,
    :file_name,
    :mime_type,
    :message_id,
    :message_thread_id,
    :media_group_id
  ]
  defstruct @fields
  @type t :: %__MODULE__{}

  def encode(items) when is_list(items) and length(items) in 2..10 do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      if is_map(item) and Map.get(item, :datatype) in ["image", "video", "audio", "file"] and
           is_binary(Map.get(item, :data)) do
        wire =
          item
          |> Map.take(@fields)
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.update!(:data, &Base.encode64/1)

        {:cont, {:ok, [wire | acc]}}
      else
        {:halt, invalid(:invalid_payload)}
      end
    end)
    |> case do
      {:ok, wire} -> {:ok, Jason.encode!(Enum.reverse(wire))}
      error -> error
    end
  end

  def encode(_), do: invalid(:invalid_payload)

  # Count both JSON delimiters and each member's base64 data without encoding files.
  def encoded_size(items, limit) when is_list(items) and length(items) in 2..10 do
    initial = 2 + length(items) - 1

    Enum.reduce_while(items, {:ok, initial}, fn item, {:ok, size} ->
      if is_map(item) and Map.get(item, :datatype) in ["image", "video", "audio", "file"] and
           is_binary(Map.get(item, :data)) do
        data_size = ExironClient.PayloadLimit.encoded_size(byte_size(item.data))

        if size + data_size > limit do
          {:halt, too_large(limit)}
        else
          metadata =
            item
            |> Map.take(@fields)
            |> Map.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.put(:data, "")

          total = size + data_size + (metadata |> Jason.encode_to_iodata!() |> IO.iodata_length())
          if total > limit, do: {:halt, too_large(limit)}, else: {:cont, {:ok, total}}
        end
      else
        {:halt, invalid(:invalid_payload)}
      end
    end)
  end

  def encoded_size(_, _), do: invalid(:invalid_payload)

  defp too_large(limit),
    do:
      {:error,
       Error.new(:payload_too_large, "encoded album exceeds request limit of #{limit} bytes")}

  def decode(data) do
    with {:ok, items} when is_list(items) and length(items) in 1..10 <- Jason.decode(data) do
      Enum.reduce_while(items, {:ok, []}, fn
        %{"datatype" => datatype, "data" => data} = item, {:ok, acc}
        when datatype in ["image", "video", "audio", "file"] ->
          case Wire.Payload.decode_message(data) do
            {:ok, bytes} ->
              fields =
                Map.new(@fields, &{&1, Map.get(item, Atom.to_string(&1))})
                |> Map.put(:data, bytes)

              {:cont, {:ok, [struct!(__MODULE__, fields) | acc]}}

            _ ->
              {:halt, invalid(:invalid_response)}
          end

        _, _ ->
          {:halt, invalid(:invalid_response)}
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    else
      _ -> invalid(:invalid_response)
    end
  end

  defp invalid(reason), do: {:error, Error.new(reason, "invalid media album")}
end
