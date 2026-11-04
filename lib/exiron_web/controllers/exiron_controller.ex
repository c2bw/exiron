defmodule ExironWeb.ExironController do
  use ExironWeb, :controller

  alias Exiron.Hub
  alias ExironWeb.ExironController.{ApiSpec, Request, Response}

  # OpenApiSpex resolves operations from the routed controller module. Keep
  # this small adapter here while the declarations live in ApiSpec.
  def open_api_operation(action), do: ApiSpec.open_api_operation(action)
  def shared_tags, do: ApiSpec.shared_tags()
  def shared_security, do: ApiSpec.shared_security()

  def status(conn, _params) do
    with_credential(conn, &Hub.status_for_token/1)
  end

  def capabilities(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_credential(conn, fn credential ->
      with {:ok, result} <- Hub.authenticate(credential) do
        {:ok, result |> Response.auth_payload() |> Map.take([:protocol_version, :capabilities])}
      end
    end)
  end

  def auth(conn, params) do
    token = params["hook_token"] || Request.bearer_token(conn)

    Response.render_result(
      conn,
      with({:ok, result} <- Hub.authenticate(token), do: {:ok, Response.auth_payload(result)})
    )
  end

  def requests(conn, params) do
    with_credential(conn, fn credential ->
      opts = [
        client_id: params["client_id"],
        client_identity: Request.client_identity(conn),
        listen: Request.listen_mode(params["listen"]),
        delivery_ack: params["delivery_ack"]
      ]

      case params["delivery_mode"] do
        "explicit" ->
          Hub.poll_delivery(credential, opts)

        _mode ->
          with {:ok, requests} <- Hub.poll(credential, opts), do: {:ok, %{requests: requests}}
      end
    end)
  end

  def delivery(conn, params),
    do: with_credential(conn, &Hub.delivery_diagnostics(&1, params["id"]))

  def retire_client(conn, params),
    do: with_credential(conn, &Hub.retire_client(&1, params["client_id"], params["delivery_id"]))

  def renew_lease(conn, params),
    do: with_credential(conn, &Hub.renew_lease(&1, params["client_id"], params["delivery_id"]))

  def client_runtime_report(conn, params),
    do: with_credential(conn, &Hub.client_runtime_report(&1, params))

  def handler_report(conn, params),
    do: with_credential(conn, &Hub.handler_report(&1, params))

  def request_state(conn, params),
    do: with_credential(conn, &Hub.request_state(&1, params["req_id"]))

  def cancellations(conn, params), do: with_credential(conn, &Hub.cancel(&1, params["req_id"]))

  def responses(conn, params) do
    with_payload(conn, params, fn credential, data, opts ->
      Hub.respond(
        credential,
        params["req_id"],
        params["datatype"],
        data,
        opts
      )
    end)
  end

  def idempotent_responses(conn, params) do
    if is_binary(params["idempotency_key"]) and params["idempotency_key"] != "",
      do: responses(conn, params),
      else: Response.render_result(conn, {:error, :invalid_payload})
  end

  def idempotent_push(conn, params) do
    if is_binary(params["idempotency_key"]) and params["idempotency_key"] != "",
      do: __MODULE__.push(conn, params),
      else: Response.render_result(conn, {:error, :invalid_payload})
  end

  def actions(conn, params) do
    with_credential(conn, fn credential ->
      Hub.action(credential, params["req_id"], Map.get(params, "action", "typing"),
        delivery_diagnostics: true
      )
    end)
  end

  def edits(conn, params) do
    with_payload(conn, params, fn credential, data, opts ->
      Hub.edit(credential, params["req_id"], params["datatype"], data, opts)
    end)
  end

  def push(conn, params) do
    with_payload(conn, params, fn credential, data, opts ->
      with {:ok, sent} <-
             Hub.push(credential, params["datatype"], data, params["chat_id"], opts) do
        {:ok, if(is_map(sent), do: Map.put(sent, :ok, true), else: %{ok: true, sent: sent})}
      end
    end)
  end

  defp with_payload(conn, params, fun) do
    with_credential(conn, fn credential ->
      with {:ok, data} <- Request.decode_data(params) do
        fun.(
          credential,
          data,
          Keyword.put(Request.message_opts(params), :delivery_diagnostics, true)
        )
      end
    end)
  end

  defp with_credential(conn, fun) do
    result =
      with {:ok, credential} <- Request.authenticated_credential(conn) do
        fun.(credential)
      end

    Response.render_result(conn, result)
  end
end
