defmodule Exiron.Hub.Telegram.Outbound do
  @moduledoc false

  alias Exiron.Hub.Message
  alias Exiron.Hub.Telegram.BotRegistry

  def send(%BotRegistry{} = bots, sender, %Message{} = message) do
    message = Exiron.Hub.DeliveryDiagnostics.group(message)

    cond do
      message.datatype in ["image", "video", "audio", "file", "album"] ->
        Exiron.Hub.Telegram.CaptionDelivery.send(message, fn part, bound_token ->
          if bound_token,
            do: send_with_token(bots, sender, bound_token, part),
            else: send_single(bots, sender, part)
        end)

      Exiron.Hub.Telegram.TextDelivery.multipart?(message) ->
        Exiron.Hub.Telegram.TextDelivery.send(message, fn part, bound_token ->
          if bound_token,
            do: send_with_token(bots, sender, bound_token, part),
            else: send_single(bots, sender, part)
        end)

      true ->
        Exiron.Hub.DeliveryDiagnostics.plan(message)
        send_single(bots, sender, message)
    end
  end

  defp send_single(bots, sender, message) do
    with {:ok, tokens} <- tokens_for(bots, message) do
      send_with_tokens(bots, sender, tokens, message)
    else
      {:error, reason} = error ->
        Exiron.Hub.DeliveryDiagnostics.report(
          {:blocked, Exiron.Hub.DeliveryDiagnostics.metadata(message),
           Exiron.Hub.DeliveryDiagnostics.error(reason)}
        )

        error
    end
  end

  def annotate(%BotRegistry{} = bots, %Message{} = message) do
    sent_message(bots, message.bot_token, message)
  end

  defp tokens_for(bots, %Message{edit_message_id: id, bot_token: token, chat_id: chat_id})
       when is_integer(id) do
    if is_binary(token) and BotRegistry.configured_token?(bots, chat_id, token),
      do: {:ok, [token]},
      else: {:error, :telegram_bot_not_configured}
  end

  defp tokens_for(bots, %Message{bot_token: token, chat_id: chat_id} = message)
       when is_binary(token) do
    if BotRegistry.configured_token?(bots, chat_id, token) do
      {:ok, candidate_tokens(bots, chat_id, token)}
    else
      fallback_tokens_for(bots, message)
    end
  end

  defp tokens_for(bots, %Message{} = message), do: fallback_tokens_for(bots, message)

  defp fallback_tokens_for(bots, %Message{chat_id: chat_id, bot_name: bot_name})
       when is_binary(bot_name) and bot_name != "" do
    case BotRegistry.bot_for_name(bots, chat_id, bot_name) do
      {:ok, %{token: token}} -> {:ok, candidate_tokens(bots, chat_id, token)}
      {:error, :telegram_bot_not_configured} -> default_tokens_for(bots, chat_id)
    end
  end

  defp fallback_tokens_for(bots, %Message{chat_id: chat_id}) do
    default_tokens_for(bots, chat_id)
  end

  defp default_tokens_for(bots, chat_id) do
    case BotRegistry.default_token(bots, chat_id) do
      {:ok, token} -> {:ok, candidate_tokens(bots, chat_id, token)}
      :error -> {:error, :telegram_bot_not_configured}
    end
  end

  defp candidate_tokens(bots, chat_id, token) do
    [token | BotRegistry.alternate_tokens(bots, chat_id, token)]
    |> Enum.uniq()
  end

  defp send_with_tokens(_bots, _sender, [], _message),
    do: {:error, :telegram_bot_not_configured}

  defp send_with_tokens(bots, sender, [token], message) do
    send_with_token(bots, sender, token, message)
  end

  defp send_with_tokens(bots, sender, [token | tokens], message) do
    case send_with_token(bots, sender, token, message) do
      {:ok, message} ->
        {:ok, message}

      {:error, %ExGram.Error{code: code}} when code in [401, 403] ->
        send_with_tokens(bots, sender, tokens, message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_with_token(bots, sender, token, message) do
    sent_message = sent_message(bots, token, message)

    case Exiron.Hub.Telegram.SendCoordinator.run(
           token,
           fn ->
             Exiron.Hub.SendTasks.telegram_attempt(sent_message, fn ->
               sender.(token, sent_message)
             end)
           end,
           chat_id: sent_message.chat_id,
           bot_name: sent_message.bot_name
         ) do
      :ok ->
        {:ok, sent_message}

      {:ok, receipt} when is_map(receipt) ->
        {:ok, %{sent_message | message_id: Map.get(receipt, :message_id)}}

      {:ok, receipts} when is_list(receipts) ->
        first = List.first(receipts) || %{}

        {:ok,
         %{
           sent_message
           | message_id: Map.get(first, :message_id),
             media_group_id: Map.get(first, :media_group_id),
             media_message_ids: Enum.map(receipts, &Map.get(&1, :message_id))
         }}

      {:ok, true} ->
        {:ok, sent_message}

      {:error, %ExGram.Error{metadata: %{exiron_suppressed: true}} = reason} ->
        Exiron.Hub.DeliveryDiagnostics.report(
          {:blocked, Exiron.Hub.DeliveryDiagnostics.metadata(sent_message),
           Exiron.Hub.DeliveryDiagnostics.error(reason)}
        )

        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sent_message(bots, token, %Message{} = message) do
    case BotRegistry.config_for(bots, message.chat_id, token) do
      nil ->
        message

      config ->
        %{
          message
          | instance: token,
            wire_instance: Map.get(config, :bot_name),
            bot_token: token,
            bot_name: Map.get(config, :bot_name)
        }
    end
  end
end
