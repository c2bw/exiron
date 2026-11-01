defmodule Exiron.Hub.DeliveryHealth do
  @moduledoc false

  alias Exiron.Hub.Router
  alias Exiron.Telemetry

  def empty do
    %{
      unavailable_rejections: 0,
      overload_rejections: 0,
      send_capacity_rejections: 0,
      send_byte_capacity_rejections: 0,
      send_failures: 0,
      completed_responses: 0,
      response_duration_ms: 0,
      last_response_ms: nil,
      last_connected_at: nil,
      last_disconnected_at: nil
    }
  end

  def for_hook(state, hook), do: Map.get(state.health, hook, empty())

  def reject(state, hook, reason) when reason in [:unavailable, :overloaded] do
    Telemetry.rejection(hook, reason)
    key = if reason == :unavailable, do: :unavailable_rejections, else: :overload_rejections
    update(state, hook, &Map.update!(&1, key, fn count -> count + 1 end))
  end

  def send_capacity_rejected(state, hook) do
    update(state, hook, &Map.update!(&1, :send_capacity_rejections, fn count -> count + 1 end))
  end

  def send_bytes_rejected(state, hook) do
    update(
      state,
      hook,
      &Map.update!(&1, :send_byte_capacity_rejections, fn count -> count + 1 end)
    )
  end

  def send_failed(state, hook) do
    update(state, hook, &Map.update!(&1, :send_failures, fn count -> count + 1 end))
  end

  def connected(state, hook, action, at) do
    key = if action == "connected", do: :last_connected_at, else: :last_disconnected_at
    update(state, hook, &Map.put(&1, key, at))
  end

  def response_completed(state, hook, pending) do
    case Map.get(pending || %{}, :accepted_at) do
      accepted_at when is_integer(accepted_at) ->
        duration = max(System.monotonic_time() - accepted_at, 0)
        Telemetry.response(duration, hook)
        milliseconds = System.convert_time_unit(duration, :native, :microsecond) / 1000

        update(state, hook, fn health ->
          %{
            health
            | completed_responses: health.completed_responses + 1,
              response_duration_ms: health.response_duration_ms + milliseconds,
              last_response_ms: milliseconds
          }
        end)

      _missing ->
        state
    end
  end

  def summary(hooks) do
    totals =
      Enum.reduce(
        hooks,
        %{
          queued: 0,
          queued_bytes: 0,
          pending: 0,
          in_flight_sends: 0,
          unavailable_rejections: 0,
          overload_rejections: 0,
          send_capacity_rejections: 0,
          send_byte_capacity_rejections: 0,
          send_failures: 0,
          completed_responses: 0,
          response_duration_ms: 0
        },
        fn hook, totals ->
          Map.new(totals, fn {key, value} -> {key, value + Map.fetch!(hook.health, key)} end)
        end
      )

    average =
      if totals.completed_responses > 0,
        do: totals.response_duration_ms / totals.completed_responses,
        else: nil

    Map.put(totals, :average_response_ms, average)
  end

  # Keep one fixed-size record per configured hook; stale completions after a
  # route reload must not recreate records for hooks that have been removed.
  defp update(%{router: %Router{hooks: hooks}} = state, hook, fun) do
    if Map.has_key?(hooks, hook) do
      %{state | health: Map.put(state.health, hook, fun.(for_hook(state, hook)))}
    else
      state
    end
  end

  defp update(state, _hook, _fun), do: state
end
