defmodule ExironClient do
  @moduledoc """
  HTTP client for Exiron hooks.

  The client talks to the Exiron server's `/api` endpoints and exposes decoded
  payloads as plain Elixir binaries. Request data sent by the server is base64
  decoded before it is returned, and response or push payloads are base64
  encoded before they are sent.
  """

  alias ExironClient.{Auth, Endpoint, Error, Message}
  alias ExironClient.Validation

  @typedoc "Supported Exiron payload datatype."
  @type datatype :: String.t()

  @typedoc "Client configuration."
  @type t :: %__MODULE__{
          base_url: String.t(),
          token: String.t() | nil,
          req_options: keyword(),
          websocket_tls_options: keyword(),
          allow_insecure_websocket_tls?: boolean(),
          reconnect_backoff: keyword(),
          client_id: String.t(),
          listen?: boolean() | :all,
          max_response_bytes: pos_integer(),
          max_request_bytes: pos_integer()
        }

  @default_max_request_bytes 51 * 1024 * 1024
  @default_max_response_bytes 128 * 1024 * 1024
  @base_url_schemes ~w(http https ws wss)

  @default_reconnect_backoff [
    initial_delay_ms: 250,
    jitter: true,
    max_delay_ms: 30_000,
    max_retry_time_ms: 30_000,
    sleep: &Process.sleep/1
  ]

  @derive {Inspect, only: [:base_url, :client_id, :listen?]}
  defstruct [
    :base_url,
    :token,
    :client_id,
    on_request: nil,
    listen?: false,
    max_response_bytes: @default_max_response_bytes,
    max_request_bytes: @default_max_request_bytes,
    req_options: [],
    websocket_tls_options: [],
    allow_insecure_websocket_tls?: false,
    reconnect_backoff: @default_reconnect_backoff
  ]

  @doc """
  Builds a new Exiron client.

  ## Options

    * `:base_url` - required absolute server URL without a query or fragment, for
      example `"http://localhost:4000"`. `ws` and `wss` schemes are accepted and
      normalized to their corresponding HTTP schemes.
    * `:token` - optional hook token used as the bearer token for authenticated calls
    * `:client_id` - optional stable client instance identifier. Defaults to a generated value
    * `:listen` - include listen-style Telegram messages while polling. Use `:all`
      to also receive routed matches as listen messages. Defaults to `false`
    * `:req_options` - extra options merged into every `Req` call
    * `:on_request` - optional completion callback receiving sanitized logical HTTP
      API request metadata. Must return promptly; callback failures are isolated.
    * `:websocket_tls_options` - extra `:ssl` options for `wss://` connections.
      The client still enforces peer and hostname verification by default.
      Use this for custom CA material such as `cacerts: ...` or
      `cacertfile: ...`.
    * `:allow_insecure_websocket_tls` - development/test-only escape hatch that
      disables `wss://` certificate and hostname verification when set to
      `true`. Defaults to `false`; do not enable this in production.
    * `:max_request_bytes` - maximum complete outgoing JSON body, including base64
      and metadata. Defaults to 51 MiB; align with the server upload limit.
    * `:max_response_bytes` - maximum HTTP response body or WebSocket message
      size. Defaults to 128 MiB.
    * `:reconnect_backoff` - retry strategy for safe transport failures and HTTP 429. Defaults to
      exponential backoff starting at 250ms, capped at 30s, and giving up after
      30s total retry time. Ordinary delays use equal jitter by default;
      set `jitter: false` for deterministic delays. Server hints are never shortened.

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    base_url =
      opts
      |> Keyword.fetch!(:base_url)
      |> normalize_base_url()

    %__MODULE__{
      base_url: base_url,
      token: Keyword.get(opts, :token),
      client_id: Keyword.get_lazy(opts, :client_id, &new_client_id/0),
      on_request: ExironClient.RequestObserver.validate!(Keyword.get(opts, :on_request)),
      listen?: normalize_listen(Keyword.get(opts, :listen, false)),
      max_request_bytes:
        Validation.positive_integer_option!(opts, :max_request_bytes, @default_max_request_bytes),
      max_response_bytes:
        Validation.positive_integer_option!(
          opts,
          :max_response_bytes,
          @default_max_response_bytes
        ),
      req_options: Keyword.get(opts, :req_options, []),
      websocket_tls_options:
        opts
        |> Keyword.get(:websocket_tls_options, [])
        |> websocket_tls_options!(),
      allow_insecure_websocket_tls?: boolean_option!(opts, :allow_insecure_websocket_tls, false),
      reconnect_backoff:
        opts
        |> Keyword.get(:reconnect_backoff, [])
        |> reconnect_backoff()
    }
  end

  @doc """
  Authenticates a hook token.

  Returns the server auth payload, including the authenticated hook name.
  """
  @spec auth(t(), String.t() | nil) :: {:ok, Auth.t()} | {:error, Error.t()}
  def auth(%__MODULE__{} = client, hook_token \\ nil),
    do: Endpoint.auth(client, hook_token)

  @doc """
  Fetches queued routed requests for the authenticated hook.

  This one-shot operation is not retried after transport errors because
  the server may already have drained the queue. Use the managed poller for
  explicit delivery acknowledgement and recoverable polling.
  """
  @spec requests(t(), keyword()) :: {:ok, [Message.t()]} | {:error, Error.t()}
  def requests(%__MODULE__{} = client, request_opts \\ []) when is_list(request_opts),
    do: Endpoint.requests(client, request_opts)

  @doc "Acknowledge a completed owned batch and release its session without fetching work."
  def retire_delivery(%__MODULE__{} = client, delivery_id, opts \\ []) do
    with {:ok, %{"ok" => true}} <-
           ExironClient.Request.request(
             client,
             :post,
             "/api/client-retire",
             Keyword.put(opts, :json, %{client_id: client.client_id, delivery_id: delivery_id})
           ) do
      :ok
    else
      {:error, _} = error ->
        error

      _ ->
        {:error, ExironClient.Error.new(:invalid_response, "invalid client retirement response")}
    end
  end

  @doc false
  def requests_delivery(
        %__MODULE__{} = client,
        delivery_ack \\ nil,
        request_opts \\ []
      )
      when is_list(request_opts) do
    Endpoint.requests_delivery(client, delivery_ack, request_opts)
  end

  @doc """
  Sends a response for a routed request.
  """
  @spec respond(t(), Message.t() | String.t(), datatype(), binary()) ::
          {:ok, map()} | {:error, Error.t()}
  def respond(%__MODULE__{} = client, request_or_id, datatype, data),
    do: Endpoint.respond(client, request_or_id, datatype, data, [])

  @spec respond(t(), Message.t() | String.t(), datatype(), binary(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def respond(%__MODULE__{} = client, request_or_id, datatype, data, opts)
      when is_binary(datatype) and is_binary(data) and is_list(opts) do
    Endpoint.respond(client, request_or_id, datatype, data, opts)
  end

  @doc "Renew only this client's existing HTTP delivery lease, without fetching or acknowledging work."
  def renew_http_lease(%__MODULE__{} = client, batch, opts \\ []),
    do: Endpoint.renew_http_lease(client, batch, opts)

  @doc "Discover protocol support without consuming work. Falls back to auth only for a missing/unsupported route."
  def capabilities(%__MODULE__{} = client), do: Endpoint.capabilities(client)

  @doc "Read request state without consuming work or renewing a polling lease."
  def request_state(%__MODULE__{} = client, request_or_id),
    do: Endpoint.request_state(client, request_or_id)

  @doc "Inspect a delivery by diagnostic ID, or the latest operation for a request ID."
  def delivery_status(%__MODULE__{} = client, id), do: Endpoint.delivery_status(client, id)

  @doc "Cancel a pending request and its remaining sends. Returns delivery status and known message IDs."
  def cancel_request(%__MODULE__{} = client, request_or_id),
    do: Endpoint.cancel(client, request_or_id)

  @doc "Send or replace a partial text reply without completing its request. Opt-in."
  def update_text(%__MODULE__{} = client, request_or_id, text, opts \\ []) do
    respond(
      client,
      request_or_id,
      "text",
      text,
      opts |> Keyword.put(:final, false) |> Keyword.put_new(:parse_mode, "plain")
    )
  end

  @doc "Stream UTF-8 chunks into one text reply, coalescing updates and finalizing at the end."
  def stream_text(%__MODULE__{} = client, request_or_id, chunks, opts \\ []),
    do: ExironClient.TextStream.run(client, request_or_id, chunks, opts)

  @doc "Edits the message containing a clicked button and completes that callback request."
  def edit_callback_text(client, request_or_id, text, opts \\ []),
    do:
      respond(
        client,
        request_or_id,
        "text",
        text,
        opts |> Keyword.put(:edit_origin, true) |> Keyword.put_new(:parse_mode, "plain")
      )

  @doc "Replace or remove buttons on a retained completed reply, without changing its content."
  def edit_keyboard(client, request_or_id, keyboard),
    do: Endpoint.edit_keyboard(client, request_or_id, keyboard)

  @doc "Replace or remove buttons on the clicked message, completing its callback request."
  def edit_callback_keyboard(client, request_or_id, keyboard),
    do:
      respond(client, request_or_id, "keyboard", "", edit_origin: true, inline_keyboard: keyboard)

  @doc "Edit a retained completed text reply by its original request ID."
  def edit_text(%__MODULE__{} = client, request_or_id, text, opts \\ []),
    do: Endpoint.edit(client, request_or_id, text, Keyword.put_new(opts, :parse_mode, "plain"))

  @doc "Send a short-lived Telegram action in the pending request's chat and topic."
  def chat_action(%__MODULE__{} = client, request_or_id, action \\ "typing"),
    do: Endpoint.action(client, request_or_id, action)

  def typing(%__MODULE__{} = client, request_or_id), do: chat_action(client, request_or_id)

  def reply_album(%__MODULE__{} = client, request_or_id, items, opts \\ []) do
    Endpoint.respond_album(client, request_or_id, items, opts)
  end

  def push_album(%__MODULE__{} = client, items, opts \\ []) do
    Endpoint.push_album(client, items, opts)
  end

  def push_album_to_chat(%__MODULE__{} = client, chat_id, items, opts \\ []) do
    Endpoint.push_album(client, chat_id, items, opts)
  end

  @doc """
  Pushes a payload to all push-enabled targets for the authenticated hook.
  """
  @spec push(t(), datatype(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def push(%__MODULE__{} = client, datatype, data)
      when is_binary(datatype) and is_binary(data) do
    push(client, datatype, data, [])
  end

  @spec push(t(), datatype(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def push(%__MODULE__{} = client, datatype, data, opts)
      when is_binary(datatype) and is_binary(data) and is_list(opts) do
    Endpoint.push(client, datatype, data, opts)
  end

  @doc """
  Pushes a payload to a specific push-enabled chat for the authenticated hook.
  """
  @spec push(t(), integer(), datatype(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def push(%__MODULE__{} = client, chat_id, datatype, data)
      when is_integer(chat_id) and is_binary(datatype) and is_binary(data) do
    push(client, chat_id, datatype, data, [])
  end

  @spec push(t(), integer(), datatype(), binary(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def push(%__MODULE__{} = client, chat_id, datatype, data, opts)
      when is_integer(chat_id) and is_binary(datatype) and is_binary(data) and is_list(opts) do
    Endpoint.push(client, chat_id, datatype, data, opts)
  end

  @doc """
  Fetches Exiron status scoped to the client's authenticated hook.
  """
  @spec status(t()) :: {:ok, map()} | {:error, Error.t()}
  def status(%__MODULE__{} = client) do
    Endpoint.status(client)
  end

  @doc """
  Convenience wrapper for `respond/4` with the `"text"` datatype.
  """
  @spec reply_text(t(), Message.t() | String.t(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def reply_text(%__MODULE__{} = client, request_or_id, text) when is_binary(text) do
    respond(client, request_or_id, "text", text)
  end

  @doc """
  Convenience wrapper for `respond/5` with the `"sticker"` datatype.
  """
  @spec reply_sticker(t(), Message.t() | String.t(), binary(), binary()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply_sticker(%__MODULE__{} = client, request_or_id, sticker_file_id, emoji \\ "")
      when is_binary(sticker_file_id) and is_binary(emoji) do
    respond(client, request_or_id, "sticker", sticker_file_id, sticker_emoji: emoji)
  end

  @doc """
  Convenience wrapper for `push/3` with the `"text"` datatype.
  """
  @spec push_text(t(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def push_text(%__MODULE__{} = client, text) when is_binary(text) do
    push(client, "text", text)
  end

  @spec push_text(t(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def push_text(%__MODULE__{} = client, text, opts) when is_binary(text) and is_list(opts) do
    push(client, "text", text, opts)
  end

  @doc """
  Convenience wrapper for `push/4` with the `"text"` datatype.
  """
  @spec push_text(t(), integer(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def push_text(%__MODULE__{} = client, chat_id, text)
      when is_integer(chat_id) and is_binary(text) do
    push(client, chat_id, "text", text)
  end

  @spec push_text(t(), integer(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def push_text(%__MODULE__{} = client, chat_id, text, opts)
      when is_integer(chat_id) and is_binary(text) and is_list(opts) do
    push(client, chat_id, "text", text, opts)
  end

  @doc """
  Convenience wrapper for `push/4` with the `"sticker"` datatype.
  """
  @spec push_sticker(t(), binary(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def push_sticker(%__MODULE__{} = client, sticker_file_id, emoji \\ "")
      when is_binary(sticker_file_id) and is_binary(emoji) do
    push(client, "sticker", sticker_file_id, sticker_emoji: emoji)
  end

  @spec push_sticker(t(), binary(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def push_sticker(%__MODULE__{} = client, sticker_file_id, emoji, opts)
      when is_binary(sticker_file_id) and is_binary(emoji) and is_list(opts) do
    push(client, "sticker", sticker_file_id, Keyword.put(opts, :sticker_emoji, emoji))
  end

  @doc """
  Convenience wrapper for `push/5` with the `"sticker"` datatype.
  """
  @spec push_sticker(t(), integer(), binary(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def push_sticker(%__MODULE__{} = client, chat_id, sticker_file_id, emoji)
      when is_integer(chat_id) and is_binary(sticker_file_id) and is_binary(emoji) do
    push(client, chat_id, "sticker", sticker_file_id, sticker_emoji: emoji)
  end

  @spec push_sticker(t(), integer(), binary(), binary(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def push_sticker(%__MODULE__{} = client, chat_id, sticker_file_id, emoji, opts)
      when is_integer(chat_id) and is_binary(sticker_file_id) and is_binary(emoji) and
             is_list(opts) do
    push(client, chat_id, "sticker", sticker_file_id, Keyword.put(opts, :sticker_emoji, emoji))
  end

  defp reconnect_backoff(opts) do
    backoff = Keyword.merge(@default_reconnect_backoff, opts)
    unless is_boolean(backoff[:jitter]), do: raise(ArgumentError, ":jitter must be a boolean")
    initial_delay_ms = Validation.positive_integer_option!(backoff, :initial_delay_ms)

    backoff
    |> Keyword.put(:max_delay_ms, Validation.positive_integer_option!(backoff, :max_delay_ms))
    |> Keyword.put(
      :max_retry_time_ms,
      Validation.positive_integer_option!(backoff, :max_retry_time_ms)
    )
    |> Keyword.put(:current_delay_ms, initial_delay_ms)
  end

  defp new_client_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp normalize_base_url(url) when is_binary(url) do
    url = String.trim_trailing(url, "/")

    with {:ok, uri} <- URI.new(url),
         :ok <- validate_base_url(uri) do
      uri
      |> Map.put(:scheme, http_scheme(uri.scheme))
      |> URI.to_string()
    else
      _error -> invalid_base_url!()
    end
  end

  defp normalize_base_url(_url), do: invalid_base_url!()

  defp validate_base_url(%URI{
         scheme: scheme,
         host: host,
         query: nil,
         fragment: nil
       })
       when scheme in @base_url_schemes and is_binary(host) and host != "",
       do: :ok

  defp validate_base_url(_uri), do: :error

  defp http_scheme("ws"), do: "http"
  defp http_scheme("wss"), do: "https"
  defp http_scheme(scheme), do: scheme

  defp invalid_base_url! do
    raise ArgumentError,
          "base_url must be an absolute HTTP or WebSocket URL without a query or fragment"
  end

  defp websocket_tls_options!(options) when is_list(options) do
    if Keyword.keyword?(options) do
      options
    else
      raise ArgumentError, ":websocket_tls_options must be a keyword list"
    end
  end

  defp websocket_tls_options!(_options),
    do: raise(ArgumentError, ":websocket_tls_options must be a keyword list")

  defp boolean_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      _value -> raise ArgumentError, "#{key} must be a boolean"
    end
  end

  def listen_param(:all), do: "all"
  def listen_param("all"), do: "all"
  def listen_param(true), do: "true"
  def listen_param(_listen), do: "false"

  defp normalize_listen(:all), do: :all
  defp normalize_listen("all"), do: :all
  defp normalize_listen(true), do: true
  defp normalize_listen(_listen), do: false
end
