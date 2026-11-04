defmodule ExironClient.Request do
  @moduledoc false

  alias ExironClient.{Error, ReconnectPolicy, Validation, Wire}

  @body_chunks_key :exiron_client_body_chunks
  @body_size_key :exiron_client_body_size
  @body_too_large_key :exiron_client_body_too_large

  def request(client, method, path, opts \\ []) do
    ExironClient.RequestObserver.run(client, method, path, fn ->
      request_unobserved(client, method, path, opts)
    end)
  end

  defp request_unobserved(client, method, path, opts) do
    opts =
      client.req_options
      |> Keyword.merge(opts)
      |> Keyword.merge(method: method, url: client.base_url <> path)
      |> ExironClient.RequestOptions.normalize()
      |> Keyword.put(:retry, false)
      |> Keyword.put(:into, response_collector(client.max_response_bytes))
      |> put_auth_header(client.token)
      |> Keyword.update(
        :headers,
        [{"x-exiron-sdk", "elixir"}, {"x-exiron-sdk-version", ExironClient.Version.current()}],
        fn headers ->
          headers
          |> Enum.reject(fn {name, _} ->
            String.downcase(to_string(name)) in ["x-exiron-sdk", "x-exiron-sdk-version"]
          end)
          |> Kernel.++([
            {"x-exiron-sdk", "elixir"},
            {"x-exiron-sdk-version", ExironClient.Version.current()}
          ])
        end
      )

    with :ok <- ExironClient.PayloadLimit.check_options(client, opts) do
      request_with_reconnect(
        opts,
        client.reconnect_backoff,
        monotonic_ms(),
        retryable_request?(method, path, opts)
      )
    end
  end

  def data(client, method, path, data, build) do
    with :ok <- ExironClient.PayloadLimit.check_data(client, byte_size(data), build.("")) do
      request(client, method, path, json: build.(data))
    end
  end

  defp request_with_reconnect(opts, backoff, started_at_ms, retryable?) do
    with {:ok, request_opts} <- ExironClient.HandlerDeadline.request_options(opts) do
      ExironClient.RequestObserver.attempt()
      result = Req.request(request_opts)
      ExironClient.RequestObserver.response(result)

      with :ok <- ExironClient.HandlerDeadline.check() do
        case result do
          {:ok, %Req.Response{} = response} ->
            handle_response(response, opts, backoff, started_at_ms, retryable?)

          {:error, %Req.TransportError{} = exception} when retryable? ->
            maybe_reconnect(opts, backoff, started_at_ms, exception, retryable?)

          {:error, %Req.TransportError{} = exception} ->
            {:error, Wire.Error.from_exception(exception)}

          {:error, exception} ->
            {:error, Wire.Error.from_exception(exception)}
        end
      end
    end
  end

  defp handle_response(response, opts, backoff, started_at_ms, retryable?) do
    with {:ok, body} <- response_body(response) do
      if response.status in 200..299 do
        {:ok, body}
      else
        response.status
        |> Wire.Error.from_response(body)
        |> ExironClient.RetryAfter.apply_header(Req.Response.get_header(response, "retry-after"))
        |> maybe_reconnect_hook_client(opts, backoff, started_at_ms, retryable?)
      end
    end
  end

  defp response_collector(max_response_bytes) do
    fn {:data, data}, {request, response} ->
      size = Map.get(response.private, @body_size_key, 0)

      if byte_size(data) > max_response_bytes - size do
        response = %{
          response
          | body: "",
            private: Map.put(response.private, @body_too_large_key, max_response_bytes)
        }

        {:halt, {request, response}}
      else
        chunks = Map.get(response.private, @body_chunks_key, [])

        response = %{
          response
          | body: [data | chunks],
            private:
              response.private
              |> Map.put(@body_chunks_key, [data | chunks])
              |> Map.put(@body_size_key, size + byte_size(data))
        }

        {:cont, {request, response}}
      end
    end
  end

  defp response_body(%Req.Response{private: private, body: body}) do
    case Map.fetch(private, @body_too_large_key) do
      {:ok, max_response_bytes} ->
        {:error,
         Error.new(
           :invalid_response,
           "response body exceeds configured size limit of #{max_response_bytes} bytes",
           body: %{max_response_bytes: max_response_bytes}
         )}

      :error ->
        collected_response_body(private, body)
    end
  end

  defp collected_response_body(private, fallback_body) do
    case Map.fetch(private, @body_chunks_key) do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary() |> decode_json()}
      :error -> {:ok, fallback_body}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _error} -> body
    end
  end

  defp maybe_reconnect_hook_client(%Error{} = error, opts, backoff, started_at_ms, true) do
    if (Error.hook_already_connected?(error) and is_integer(error.retry_after_ms) and
          error.retry_after_ms > 0) or error.status == 429 do
      delay_ms = ReconnectPolicy.delay_ms(backoff, error)
      maybe_reconnect_after(opts, backoff, started_at_ms, delay_ms, error, true)
    else
      {:error, error}
    end
  end

  defp maybe_reconnect_hook_client(error, _opts, _backoff, _started_at_ms, _retryable?),
    do: {:error, error}

  defp maybe_reconnect(opts, backoff, started_at_ms, exception, retryable?) do
    error = Wire.Error.from_exception(exception)
    delay_ms = ReconnectPolicy.delay_ms(backoff, error)

    case maybe_reconnect_after(opts, backoff, started_at_ms, delay_ms, error, retryable?) do
      {:error, ^error} -> {:error, error}
      result -> result
    end
  end

  defp maybe_reconnect_after(opts, backoff, started_at_ms, delay_ms, error, retryable?) do
    if ReconnectPolicy.retry_budget_available?(backoff, started_at_ms, delay_ms) do
      reconnect_after(opts, backoff, started_at_ms, delay_ms, error, retryable?)
    else
      {:error, error}
    end
  end

  defp reconnect_after(opts, backoff, started_at_ms, delay_ms, error, retryable?) do
    case ExironClient.HandlerDeadline.retry_wait(backoff, delay_ms) do
      {:error, reason} ->
        {:error, reason}

      _ok ->
        if ReconnectPolicy.retry_budget_available?(backoff, started_at_ms, 0) do
          request_with_reconnect(
            opts,
            ReconnectPolicy.next_backoff(backoff, error),
            started_at_ms,
            retryable?
          )
        else
          {:error, error}
        end
    end
  end

  defp retryable_request?(:get, "/api/requests", opts), do: explicit_delivery?(opts)
  defp retryable_request?(method, _path, _opts) when method in [:get, :head, :options], do: true
  defp retryable_request?(:post, "/api/auth", _opts), do: true
  defp retryable_request?(_method, _path, _opts), do: false

  defp explicit_delivery?(opts) do
    opts
    |> Keyword.get(:params, [])
    |> Enum.any?(fn
      {key, value} when key in [:delivery_mode, "delivery_mode"] ->
        value in [:explicit, "explicit"]

      _param ->
        false
    end)
  end

  defp put_auth_header(opts, nil), do: opts

  defp put_auth_header(opts, token) do
    header = Validation.bearer_header(token)

    Keyword.update(opts, :headers, [header], fn headers ->
      [header | headers]
    end)
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end
end
