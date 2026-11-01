defmodule ExironWeb.ExironController.Request do
  @moduledoc false

  alias Exiron.Hub.AuthenticatedHook
  alias ExironWeb.BearerToken

  def authenticated_credential(conn) do
    case Map.get(conn.assigns, :api_authentication) do
      %AuthenticatedHook{} = authentication -> {:ok, authentication}
      _missing -> require_bearer(conn)
    end
  end

  def require_bearer(conn) do
    case bearer_token(conn) do
      nil -> {:error, :missing_token}
      token -> {:ok, token}
    end
  end

  def bearer_token(conn), do: BearerToken.from_conn(conn)

  def decode_data(%{"data" => data}) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64_data}
    end
  end

  def decode_data(_params), do: {:error, :invalid_payload}

  def message_opts(params) do
    []
    |> maybe_put_sticker_emoji(params)
    |> maybe_put_bot(params)
    |> then(fn opts ->
      Enum.reduce(
        [
          :idempotency_key,
          :final,
          :inline_keyboard,
          :edit_origin,
          :reply_to_original,
          :caption_overflow,
          :caption,
          :entities,
          :caption_entities,
          :file_name,
          :mime_type,
          :message_thread_id,
          :parse_mode
        ],
        opts,
        fn key, opts ->
          if Map.has_key?(params, Atom.to_string(key)),
            do: Keyword.put(opts, key, params[Atom.to_string(key)]),
            else: opts
        end
      )
    end)
  end

  def client_identity(conn) do
    with [sdk] <- Plug.Conn.get_req_header(conn, "x-exiron-sdk"),
         [version] <- Plug.Conn.get_req_header(conn, "x-exiron-sdk-version") do
      Exiron.Hub.ClientIdentity.parse(sdk, version)
    else
      _ -> nil
    end
  end

  def listen_mode("all"), do: :all
  def listen_mode("true"), do: true
  def listen_mode(true), do: true
  def listen_mode(_listen), do: false

  defp maybe_put_sticker_emoji(opts, params) do
    case Map.get(params, "sticker_emoji") do
      emoji when is_binary(emoji) and emoji != "" -> Keyword.put(opts, :sticker_emoji, emoji)
      _emoji -> opts
    end
  end

  defp maybe_put_bot(opts, params) do
    case Map.get(params, "bot") do
      bot when is_binary(bot) and bot != "" -> Keyword.put(opts, :bot, bot)
      _bot -> opts
    end
  end
end
