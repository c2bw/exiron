defmodule Exiron.Hub.InlineKeyboard do
  @moduledoc false
  alias Exiron.Hub.Identifier
  @limit 5000
  @ttl 24 * 60 * 60 * 1000

  def valid?(_type, nil), do: true
  def valid?("album", _rows), do: false

  def valid?(_type, rows) when is_list(rows) and length(rows) <= 20 do
    Enum.all?(rows, fn row ->
      is_list(row) and length(row) in 1..8 and Enum.all?(row, &valid_button?/1)
    end) and Enum.reduce(rows, 0, &(length(&1) + &2)) <= 100
  end

  def valid?(_, _), do: false

  def prepare(%{inline_keyboard: nil} = message, _request_id), do: message

  def prepare(message, request_id) do
    {rows, bindings} =
      Enum.map_reduce(message.inline_keyboard, %{}, fn row, bindings ->
        Enum.map_reduce(row, bindings, fn button, bindings ->
          text = get(button, :text)

          case get(button, :callback_data) do
            data when is_binary(data) ->
              ref = "ex:" <> Identifier.new()

              {%{text: text, callback_data: ref},
               Map.put(bindings, ref, %{data: data, origin_req_id: request_id})}

            _ ->
              {%{text: text, url: get(button, :url)}, bindings}
          end
        end)
      end)

    %{message | inline_keyboard: rows, callback_buttons: bindings}
  end

  def inherit(%{inline_keyboard: nil} = message, context) do
    %{
      message
      | inline_keyboard: Map.get(context, :inline_keyboard),
        callback_buttons: Map.get(context, :callback_buttons)
    }
  end

  def inherit(message, _context), do: message

  def remember(state, _hook, %{inline_keyboard: nil}), do: state

  def remember(state, hook, message) do
    if is_integer(message.message_id) and is_binary(message.bot_token) do
      target = target(message.bot_token, message.chat_id, message.message_id)
      now = System.monotonic_time(:millisecond)

      bindings =
        Map.reject(state.delivery.callback_bindings, fn {_id, value} ->
          value.target == target or now - value.at >= @ttl
        end)

      additions =
        Map.new(message.callback_buttons || %{}, fn {id, value} ->
          {id,
           Map.merge(value, %{
             target: target,
             hook: hook,
             bot_name: message.bot_name,
             message_thread_id: message.message_thread_id,
             text_message_ids: message.text_message_ids,
             inline_keyboard: message.inline_keyboard,
             callback_buttons: message.callback_buttons,
             at: now
           })}
        end)

      order =
        (Map.keys(additions) ++ state.delivery.callback_order)
        |> Enum.uniq()
        |> Enum.filter(&(Map.has_key?(additions, &1) or Map.has_key?(bindings, &1)))
        |> Enum.take(@limit)

      delivery = %{
        state.delivery
        | callback_bindings: Map.merge(bindings, additions) |> Map.take(order),
          callback_order: order
      }

      %{state | delivery: delivery}
    else
      state
    end
  end

  def lookup(state, token, query) do
    with %{data: ref, message: %{chat: %{id: chat}, message_id: id}} <- query,
         %{target: target, at: at} = binding <- Map.get(state.delivery.callback_bindings, ref),
         true <- target == target(token, chat, id),
         true <- System.monotonic_time(:millisecond) - at < @ttl do
      {:ok, binding}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp target(token, chat, id), do: {:crypto.hash(:sha256, token), chat, id}

  defp valid_button?(button) when is_map(button) do
    data = get(button, :callback_data)
    url = get(button, :url)

    valid_string?(get(button, :text), 256) and
      ((valid_string?(data, 64) and is_nil(url)) or
         (is_nil(data) and valid_url?(url))) and
      Enum.all?(
        Map.keys(button),
        &(&1 in [:text, :callback_data, :url, "text", "callback_data", "url"])
      )
  end

  defp valid_button?(_), do: false

  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    valid_string?(url, 2048) and not String.contains?(url, ["\r", "\n"]) and
      ((uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "") or
         (uri.scheme == "tg" and is_binary(uri.host) and uri.host != ""))
  end

  defp valid_url?(_), do: false
  defp valid_string?(s, max) when is_binary(s), do: String.valid?(s) and byte_size(s) in 1..max
  defp valid_string?(_, _), do: false
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
