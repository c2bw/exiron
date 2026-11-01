defmodule ExironClient.Wire.Payload do
  @moduledoc false

  alias ExironClient.Error

  @spec encode(binary()) :: binary()
  def encode(data) when is_binary(data), do: Base.encode64(data)

  @spec decode_message(term()) :: {:ok, binary()} | {:error, Error.t()}
  def decode_message(data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, Error.new(:invalid_response, "message data is not valid base64")}
    end
  end

  def decode_message(_data) do
    {:error, Error.new(:invalid_response, "message data is missing")}
  end

  @spec response(String.t(), String.t(), binary(), keyword()) :: map()
  def response(req_id, datatype, data, opts \\ []) do
    %{
      req_id: req_id,
      datatype: datatype,
      data: encode(data)
    }
    |> put_optional(:sticker_emoji, Keyword.get(opts, :sticker_emoji))
    |> put_optional(:bot, Keyword.get(opts, :bot))
    |> metadata(opts)
  end

  @spec push(String.t(), binary(), keyword()) :: map()
  def push(datatype, data, opts \\ []) do
    %{datatype: datatype, data: encode(data)}
    |> put_optional(:sticker_emoji, Keyword.get(opts, :sticker_emoji))
    |> put_optional(:bot, Keyword.get(opts, :bot))
    |> metadata(opts)
  end

  @spec push_to_chat(integer(), String.t(), binary(), keyword()) :: map()
  def push_to_chat(chat_id, datatype, data, opts \\ []) do
    push(datatype, data, opts)
    |> Map.put(:chat_id, chat_id)
  end

  defp metadata(payload, opts) do
    Enum.reduce(
      [
        :idempotency_key,
        :caption,
        :caption_overflow,
        :entities,
        :caption_entities,
        :file_name,
        :mime_type,
        :message_thread_id,
        :parse_mode,
        :final,
        :inline_keyboard,
        :edit_origin,
        :reply_to_original
      ],
      payload,
      fn key, payload ->
        case Keyword.fetch(opts, key) do
          {:ok, nil} -> payload
          {:ok, value} -> Map.put(payload, key, value)
          :error -> payload
        end
      end
    )
  end

  defp put_optional(payload, _key, value) when not is_binary(value) or value == "", do: payload
  defp put_optional(payload, key, value), do: Map.put(payload, key, value)
end
