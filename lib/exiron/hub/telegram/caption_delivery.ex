defmodule Exiron.Hub.Telegram.CaptionDelivery do
  @moduledoc false
  alias Exiron.Hub.{DeliveryDiagnostics, MediaAlbum}
  alias Exiron.Hub.Telegram.{CaptionFormat, TextSplitter}

  def send(message, sender) do
    with {:ok, media, overflow} <- prepare(message) do
      DeliveryDiagnostics.plan(media, length(overflow) + 1)

      with {:ok, delivered} <- sender.(media, nil) do
        send_overflow(delivered, overflow, sender)
      end
    end
  end

  def prepare(%{datatype: "album"} = message) do
    with {:ok, items} <- MediaAlbum.decode(message.data),
         true <- within_budget?(items) do
      items
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], []}, fn {item, index}, {:ok, items, overflow} ->
        case caption_parts(message, item) do
          {:ok, item, parts} ->
            {:cont, {:ok, [item | items], overflow ++ indexed(parts, index)}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, items, overflow} when length(overflow) <= 32 ->
          {:ok, %{message | media_items: Enum.reverse(items)}, overflow}

        _ ->
          {:error, :invalid_payload}
      end
    else
      _ -> {:error, :invalid_payload}
    end
  end

  def prepare(message) do
    with {:ok, media, parts} <- caption_parts(message, message) do
      {:ok, media, indexed(parts, 0)}
    end
  end

  defp caption_parts(message, media) do
    caption = Map.get(media, :caption)
    entities = Map.get(media, :caption_entities)
    mode = Map.get(media, :parse_mode) || "plain"

    cond do
      caption in [nil, ""] and entities in [nil, []] ->
        {:ok, media, []}

      not is_binary(caption) or not TextSplitter.valid?(caption) or
          String.contains?(caption, <<0>>) ->
        {:error, :invalid_payload}

      not CaptionFormat.valid?(caption, entities, mode) ->
        {:error, :invalid_payload}

      true ->
        text = %{
          message
          | datatype: "text",
            data: caption,
            entities: entities,
            parse_mode: mode,
            caption: nil,
            caption_entities: nil,
            inline_keyboard: nil,
            callback_buttons: nil,
            edit_message_id: nil,
            text_message_ids: [],
            media_items: nil,
            caption_overflow?: false
        }

        with {:ok, [first | rest]} <-
               TextSplitter.split(text, first_limit: 1024, max_parts: 33, strict_markup: true),
             true <- rest == [] or message.caption_overflow? do
          media =
            if rest == [],
              do: media,
              else:
                media
                |> Map.put(:caption, first.data)
                |> Map.put(:caption_entities, first.entities)

          {:ok, media, rest}
        else
          _ -> {:error, :invalid_payload}
        end
    end
  end

  defp within_budget?(items) do
    captions = Enum.map(items, &(Map.get(&1, :caption) || ""))

    Enum.sum(Enum.map(captions, &byte_size/1)) <= TextSplitter.max_bytes() and
      Enum.sum(Enum.map(captions, &TextSplitter.units/1)) <= TextSplitter.max_units()
  end

  defp indexed(parts, member),
    do: parts |> Enum.with_index() |> Enum.map(fn {part, i} -> {part, member, i == 0} end)

  defp send_overflow(delivered, [], _sender), do: {:ok, delivered}

  defp send_overflow(delivered, overflow, sender) do
    ids =
      if delivered.datatype == "album",
        do: delivered.media_message_ids,
        else: [delivered.message_id]

    overflow
    |> Enum.with_index(2)
    |> Enum.reduce_while({:ok, delivered}, fn {{part, member, first?}, index}, acc ->
      id = Enum.at(ids, member)

      if is_integer(id) and id > 0 do
        part = %{
          part
          | delivery_index: index,
            reply_to_message_id: if(first?, do: id),
            bot_token: delivered.bot_token,
            bot_name: delivered.bot_name,
            instance: delivered.instance,
            wire_instance: delivered.wire_instance
        }

        case sender.(part, delivered.bot_token) do
          {:ok, %{message_id: id}} when is_integer(id) and id > 0 -> {:cont, acc}
          _ -> {:halt, {:error, :telegram_delivery_timeout}}
        end
      else
        {:halt, {:error, :telegram_delivery_timeout}}
      end
    end)
  catch
    _, _ -> {:error, :telegram_delivery_timeout}
  end
end
