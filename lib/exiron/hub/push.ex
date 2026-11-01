defmodule Exiron.Hub.Push do
  @moduledoc false

  alias Exiron.Hub.{Message, Router, Telegram}

  def send(router, telegram, hook, datatype, data, chat_id, opts) do
    with {:ok, targets} <- targets(router, hook, chat_id) do
      targets
      |> Enum.reduce({[], nil, []}, fn target, {sent, error, failures} ->
        case send_to_target(telegram, target, datatype, data, opts) do
          {:ok, message} ->
            {[message | sent], error, failures}

          {:error, reason, message} ->
            {sent, first_error(error, reason), [{message, reason} | failures]}

          {:error, reason} ->
            {sent, first_error(error, reason), failures}
        end
      end)
      |> send_result()
    end
  end

  defp send_to_target(telegram, target, datatype, data, opts) do
    with {:ok, bot, opts} <- selected_bot(telegram, target, opts) do
      message =
        Message.outgoing(
          target.service_id,
          target.chat_id,
          datatype,
          data,
          bot_token(bot),
          message_opts(opts, bot)
        )

      message = Exiron.Hub.InlineKeyboard.prepare(message, nil)

      case Telegram.send_message(telegram, message) do
        :ok -> {:ok, message}
        {:ok, sent_message} -> {:ok, sent_message}
        {:error, reason} -> {:error, reason, message}
      end
    end
  end

  defp selected_bot(telegram, target, opts) do
    case Keyword.pop(opts, :bot) do
      {nil, opts} -> selected_default_bot(telegram, target, opts)
      {bot_name, opts} -> selected_bot(telegram, target.chat_id, bot_name, opts)
    end
  end

  defp selected_default_bot(telegram, %{chat_id: chat_id, default_bot: bot_name}, opts)
       when is_binary(bot_name) do
    selected_bot(telegram, chat_id, bot_name, opts)
  end

  defp selected_default_bot(_telegram, _target, opts), do: {:ok, nil, opts}

  defp selected_bot(telegram, chat_id, bot_name, opts) when is_binary(bot_name) do
    with {:ok, bot} <- Telegram.bot_for_name(telegram, chat_id, bot_name) do
      {:ok, bot, opts}
    end
  end

  defp selected_bot(_telegram, _chat_id, _bot_name, _opts), do: {:error, :invalid_payload}

  defp bot_token(nil), do: nil
  defp bot_token(%{token: token}), do: token

  defp message_opts(opts, nil), do: opts
  defp message_opts(opts, %{name: name}), do: Keyword.put(opts, :bot_name, name)

  defp send_result({sent_messages, nil, _failures}), do: {:ok, Enum.reverse(sent_messages)}

  defp send_result({sent_messages, reason, failures}),
    do: {:partial_error, reason, Enum.reverse(sent_messages), Enum.reverse(failures)}

  defp first_error(nil, reason), do: reason
  defp first_error(reason, _next_reason), do: reason

  defp targets(router, hook, nil), do: {:ok, Router.push_targets(router, hook)}

  defp targets(router, hook, chat_id) when is_integer(chat_id) do
    case Router.push_targets(router, hook, chat_id) do
      [] -> {:error, :chat_not_pushable}
      targets -> {:ok, targets}
    end
  end

  defp targets(_router, _hook, _chat_id), do: {:error, :invalid_chat_id}
end
