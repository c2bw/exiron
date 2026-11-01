defmodule Exiron.Benchmarks.NetworkObserver do
  @moduledoc false

  @events [
    [:bandit, :request, :stop],
    [:bandit, :request, :exception],
    [:thousand_island, :connection, :start],
    [:thousand_island, :connection, :stop],
    [:thousand_island, :connection, :recv],
    [:thousand_island, :connection, :async_recv],
    [:thousand_island, :connection, :recv_error]
  ]
  @paths ~w(/metrics /__bench/ingress /__bench/outcomes /api/requests /api/responses /api/status /api/socket /api/push)

  def attach(table, opts \\ []) do
    handler = {__MODULE__, self()}
    config = %{events: table, connections: opts[:connections], traces: opts[:traces]}
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.handle_event/4, config)
    handler
  end

  def attached?(handler) do
    Enum.any?(:telemetry.list_handlers([:bandit, :request, :stop]), &(&1.id == handler))
  end

  def handle_event([:thousand_island, :connection, kind], measurements, metadata, config) do
    if is_map(config) and not is_nil(config.connections) do
      table = config.connections
      ref = metadata.telemetry_span_context

      case kind do
        :start ->
          :ets.insert(
            table,
            {ref, System.monotonic_time(:millisecond), metadata.remote_port, 0, 0, 0}
          )

        :stop ->
          :ets.delete(table, ref)

        :recv_error ->
          if measurements.error == :timeout, do: update_connection(table, ref, 6, 1)

        _recv ->
          update_connection(table, ref, 4, byte_size(measurements.data))
      end
    end

    :ok
  end

  def handle_event(event, measurements, metadata, config) do
    table = if is_map(config), do: config.events, else: config

    if is_map(config) and not is_nil(config.connections) and Map.has_key?(metadata, :conn) do
      update_connection(config.connections, metadata.connection_telemetry_span_context, 5, 1)
    end

    if Map.has_key?(metadata, :error) or List.last(event) == :exception do
      path =
        case Map.get(metadata, :conn) do
          %{request_path: path} when path in @paths -> path
          nil -> "before_request"
          _ -> "other"
        end

      error =
        case Map.get(metadata, :error) || Map.get(metadata, :exception) do
          "Read timeout" -> "read_timeout"
          %Bandit.HTTPError{message: "Read timeout"} -> "read_timeout"
          _ -> "other"
        end

      duration = duration_bucket(Map.get(measurements, :duration))

      key = {List.last(event), path, error, duration}
      :ets.update_counter(table, key, {2, 1}, {key, 0})

      if is_map(config) and not is_nil(config.traces) do
        sequence = :ets.update_counter(config.traces, :sequence, {2, 1}, {:sequence, 0})

        if sequence <= 32 do
          connection =
            connection_detail(
              config.connections,
              Map.get(metadata, :connection_telemetry_span_context)
            )

          :ets.insert(
            config.traces,
            {{:trace, sequence},
             Map.merge(connection, %{
               event: List.last(event),
               path: path,
               error: error,
               duration: duration
             })}
          )
        end
      end
    end

    :ok
  end

  defp update_connection(table, ref, position, increment) do
    :ets.update_counter(table, ref, {position, increment})
  rescue
    ArgumentError -> :ok
  end

  defp connection_detail(nil, _ref), do: %{}

  defp connection_detail(table, ref) do
    case :ets.lookup(table, ref) do
      [{^ref, started, port, bytes, requests, timeouts}] ->
        %{
          remote_port: port,
          connection_age_ms: System.monotonic_time(:millisecond) - started,
          received_bytes: bytes,
          parsed_requests: requests,
          socket_read_timeouts: timeouts
        }

      [] ->
        %{}
    end
  end

  def traces(table) do
    table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:trace, sequence}, detail} -> [{sequence, detail}]
      _ -> []
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp duration_bucket(duration) when is_integer(duration) and duration >= 0 do
    milliseconds = System.convert_time_unit(duration, :native, :millisecond)

    cond do
      milliseconds < 1000 -> "under_1s"
      milliseconds < 10_000 -> "under_10s"
      milliseconds < 60_000 -> "under_60s"
      true -> "at_least_60s"
    end
  end

  defp duration_bucket(_missing), do: "unknown"

  def report(table) do
    table
    |> :ets.tab2list()
    |> Enum.sort()
    |> Enum.map(fn {{event, path, error, duration}, count} ->
      %{event: event, path: path, error: error, duration: duration, count: count}
    end)
  end
end
