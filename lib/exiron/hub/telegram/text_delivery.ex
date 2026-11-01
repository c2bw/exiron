defmodule Exiron.Hub.Telegram.TextDelivery do
  @moduledoc false
  alias Exiron.Hub.Telegram.TextSplitter

  def multipart?(%{datatype: "text"} = message),
    do: TextSplitter.units(message.data) > 4096 or length(message.text_message_ids) > 1

  def multipart?(_), do: false

  # Each part uses the normal per-bot coordinator. Once any part succeeds the
  # entire logical response stays on that bot; whole-response fallback/retry
  # would duplicate parts already delivered.
  def send(message, sender) do
    with {:ok, parts} <- TextSplitter.split(message) do
      ids =
        case message.text_message_ids do
          [] -> if message.edit_message_id, do: [message.edit_message_id], else: []
          ids -> ids
        end

      Exiron.Hub.DeliveryDiagnostics.plan(message, length(parts), ids)

      result =
        parts
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, [], nil}, fn {part, index}, {:ok, sent, bot} ->
          part = %{
            part
            | delivery_index: index + 1,
              edit_message_id: Enum.at(ids, index),
              text_message_ids: [],
              reply_to_message_id: if(index == 0, do: part.reply_to_message_id),
              inline_keyboard: if(index == 0, do: part.inline_keyboard),
              callback_buttons: if(index == 0, do: part.callback_buttons)
          }

          case safe_send(sender, part, bot) do
            {:ok, %{message_id: id} = delivered} when is_integer(id) and id > 0 ->
              {:cont, {:ok, [delivered | sent], delivered.bot_token}}

            {:error, reason} ->
              {:halt, {:error, failure(reason, sent)}}

            _ ->
              {:halt, {:error, :telegram_delivery_timeout}}
          end
        end)

      with {:ok, sent, bot} <- result,
           :ok <- remove_surplus(message, Enum.drop(ids, length(parts)), bot, sender) do
        sent = Enum.reverse(sent)
        first = hd(sent)

        {:ok,
         %{
           message
           | bot_token: first.bot_token,
             bot_name: first.bot_name,
             instance: first.instance,
             wire_instance: first.wire_instance,
             message_id: first.message_id,
             text_message_ids: Enum.map(sent, & &1.message_id)
         }}
      end
    end
  end

  defp remove_surplus(message, ids, bot, sender) do
    ids
    |> Enum.with_index(length(message.text_message_ids) - length(ids) + 1)
    |> Enum.reduce_while(:ok, fn {id, index}, :ok ->
      removal = %{
        message
        | delivery_index: index,
          datatype: "delete",
          data: "",
          edit_message_id: id,
          reply_to_message_id: nil,
          inline_keyboard: nil,
          callback_buttons: nil,
          text_message_ids: []
      }

      case safe_send(sender, removal, bot) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, {:error, :telegram_delivery_timeout}}
      end
    end)
  end

  defp safe_send(sender, message, bot) do
    sender.(message, bot)
  catch
    _, _ -> {:error, :telegram_delivery_timeout}
  end

  defp failure(%ExGram.Error{code: code} = reason, []) when is_integer(code) and code < 500,
    do: reason

  defp failure(:telegram_bot_not_configured, []), do: :telegram_bot_not_configured
  defp failure(_reason, _sent), do: :telegram_delivery_timeout
end
