defmodule ExironClient.RequestObserver do
  @moduledoc false
  alias ExironClient.Error
  @key {__MODULE__, :current}
  @routes ~w(/api/auth /api/status /api/capabilities /api/requests /api/responses /api/push /api/edits /api/actions /api/cancellations /api/request-state /api/client-lease /api/client-retire /api/client-runtime /api/handler-reports /api/idempotent/responses /api/idempotent/push)

  def validate!(nil), do: nil
  def validate!(callback) when is_function(callback, 1), do: callback
  def validate!(_), do: raise(ArgumentError, ":on_request must be a one-argument function or nil")

  def run(%{on_request: nil}, _, _, fun), do: fun.()

  def run(client, method, path, fun) do
    previous = Process.get(@key)
    Process.put(@key, %{attempts: 0, http_status: 0})
    started = System.monotonic_time(:millisecond)

    try do
      result = fun.()

      kind =
        case result do
          {:ok, _} -> :none
          {:error, error} -> Error.classify(error)
          _ -> :error
        end

      emit(client.on_request, method, path, started, kind)
      result
    catch
      kind, reason ->
        emit(client.on_request, method, path, started, :request_error)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  def attempt do
    if stats = Process.get(@key),
      do: Process.put(@key, %{stats | attempts: stats.attempts + 1, http_status: 0})
  end

  def response({:ok, %Req.Response{status: status}}) when status in 100..599 do
    if stats = Process.get(@key), do: Process.put(@key, %{stats | http_status: status})
  end

  def response(_), do: :ok

  defp emit(callback, method, path, started, kind) do
    route = URI.parse(path).path

    route =
      if is_binary(route) and String.starts_with?(route, "/api/deliveries/"),
        do: "/api/deliveries/:id",
        else: route

    method =
      if method in [:get, :post, :put, :patch, :delete, :head, :options],
        do: method |> Atom.to_string() |> String.upcase(),
        else: "OTHER"

    event =
      Map.merge(Process.get(@key), %{
        method: method,
        route: if(route in ["/api/deliveries/:id" | @routes], do: route, else: "other"),
        duration_ms: max(System.monotonic_time(:millisecond) - started, 0),
        error_kind: kind
      })

    callback.(event)
    :ok
  catch
    _, _ -> :ok
  end
end
