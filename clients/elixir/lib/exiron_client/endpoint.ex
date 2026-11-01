defmodule ExironClient.Endpoint do
  @moduledoc false

  alias ExironClient.{Error, Message, Request, Wire}

  def capabilities(client) do
    case Request.request(client, :get, "/api/capabilities") do
      {:ok, %{"protocol_version" => version, "capabilities" => caps}}
      when is_binary(version) and version != "" and is_list(caps) ->
        if Enum.all?(caps, &(is_binary(&1) and &1 != "")),
          do: {:ok, %ExironClient.Protocol{version: version, capabilities: caps}},
          else:
            {:error,
             ExironClient.Error.new(:invalid_response, "invalid capability discovery response")}

      {:ok, _} ->
        {:error,
         ExironClient.Error.new(:invalid_response, "invalid capability discovery response")}

      {:error, %ExironClient.Error{status: status}} when status in [404, 405] ->
        with {:ok, auth} <- auth(client, nil), do: {:ok, ExironClient.Auth.protocol(auth)}

      error ->
        error
    end
  end

  def auth(client, hook_token) do
    token = hook_token || client.token

    client
    |> Map.put(:token, token)
    |> Request.request(:post, "/api/auth", json: Wire.Auth.request(token))
    |> decode_auth()
  end

  def requests(client, request_opts) when is_list(request_opts) do
    params = [client_id: client.client_id, listen: ExironClient.listen_param(client.listen?)]

    with {:ok, _response, messages} <- request_messages(client, params, request_opts) do
      {:ok, messages}
    end
  end

  def requests_delivery(client, delivery_ack, request_opts) when is_list(request_opts) do
    params = [
      client_id: client.client_id,
      listen: ExironClient.listen_param(client.listen?),
      delivery_mode: "explicit"
    ]

    params =
      if is_binary(delivery_ack),
        do: Keyword.put(params, :delivery_ack, delivery_ack),
        else: params

    with {:ok, response, messages} <- request_messages(client, params, request_opts) do
      {:ok,
       %{
         delivery_id: Map.get(response, "delivery_id"),
         runtime_ref: Map.get(response, "runtime_ref"),
         messages: messages
       }}
    end
  end

  def respond(client, request_or_id, datatype, data, opts) do
    id = request_id!(request_or_id)

    with {:ok, path} <- ExironClient.Idempotency.path("responses", opts),
         do:
           Request.data(client, :post, path, data, &Wire.Payload.response(id, datatype, &1, opts))
  end

  def respond_album(client, request_or_id, items, opts) do
    metadata = Wire.Payload.response(request_id!(request_or_id), "album", "", opts)

    with :ok <- ExironClient.PayloadLimit.check_album(client, items, metadata),
         {:ok, data} <- ExironClient.MediaItem.encode(items),
         do: respond(client, request_or_id, "album", data, opts)
  end

  def push_album(client, items, opts) do
    with :ok <-
           ExironClient.PayloadLimit.check_album(
             client,
             items,
             Wire.Payload.push("album", "", opts)
           ),
         {:ok, data} <- ExironClient.MediaItem.encode(items),
         do: push(client, "album", data, opts)
  end

  def push_album(client, chat_id, items, opts) do
    metadata = Wire.Payload.push_to_chat(chat_id, "album", "", opts)

    with :ok <- ExironClient.PayloadLimit.check_album(client, items, metadata),
         {:ok, data} <- ExironClient.MediaItem.encode(items),
         do: push(client, chat_id, "album", data, opts)
  end

  def delivery_status(client, id) when is_binary(id) do
    Request.request(client, :get, "/api/deliveries/" <> URI.encode(id, &URI.char_unreserved?/1))
  end

  def renew_http_lease(client, batch, opts) do
    Request.request(
      client,
      :post,
      "/api/client-lease",
      Keyword.put(opts, :json, %{client_id: client.client_id, delivery_id: batch})
    )
  end

  def request_state(client, request_or_id) do
    Request.request(client, :get, "/api/request-state",
      params: [req_id: request_id!(request_or_id)]
    )
  end

  def cancel(client, request_or_id) do
    Request.request(client, :post, "/api/cancellations",
      json: %{req_id: request_id!(request_or_id)}
    )
  end

  def action(client, request_or_id, action) do
    Request.request(client, :post, "/api/actions",
      json: %{req_id: request_id!(request_or_id), action: action}
    )
  end

  def edit(client, request_or_id, text, opts) do
    if is_nil(opts[:idempotency_key]),
      do:
        Request.data(
          client,
          :post,
          "/api/edits",
          text,
          &Wire.Payload.response(request_id!(request_or_id), "text", &1, opts)
        ),
      else:
        {:error,
         ExironClient.Error.new(
           :invalid_payload,
           "idempotency keys are supported only for responses and pushes"
         )}
  end

  def edit_keyboard(client, request_or_id, keyboard) do
    payload =
      Wire.Payload.response(request_id!(request_or_id), "keyboard", "", inline_keyboard: keyboard)

    Request.request(client, :post, "/api/edits", json: payload)
  end

  def push(client, datatype, data, opts) do
    with {:ok, path} <- ExironClient.Idempotency.path("push", opts),
         do: Request.data(client, :post, path, data, &Wire.Payload.push(datatype, &1, opts))
  end

  def push(client, chat_id, datatype, data, opts) do
    with {:ok, path} <- ExironClient.Idempotency.path("push", opts),
         do:
           Request.data(
             client,
             :post,
             path,
             data,
             &Wire.Payload.push_to_chat(chat_id, datatype, &1, opts)
           )
  end

  def status(client), do: Request.request(client, :get, "/api/status")

  defp decode_auth({:ok, response}), do: {:ok, Wire.Auth.decode(response)}
  defp decode_auth(error), do: error

  defp request_messages(client, params, request_opts) do
    opts = Keyword.merge([params: params], request_opts)

    with {:ok, %{"requests" => requests} = response} <-
           Request.request(client, :get, "/api/requests", opts),
         {:ok, messages} <- decode_messages(requests, :request) do
      {:ok, response, messages}
    end
  end

  defp decode_messages(messages, fallback_type) when is_list(messages),
    do: Wire.Message.decode_list(messages, fallback_type)

  defp decode_messages(_messages, _fallback_type) do
    {:error, Error.new(:invalid_response, "expected requests to be a list")}
  end

  defp request_id!(%Message{req_id: request_id}) when is_binary(request_id), do: request_id
  defp request_id!(request_id) when is_binary(request_id), do: request_id
end
