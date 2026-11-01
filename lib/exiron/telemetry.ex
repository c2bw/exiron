defmodule Exiron.Telemetry do
  @moduledoc false

  @spec queue(non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def queue(count, bytes, dropped, hook) do
    execute([:hub, :queue], %{count: count, bytes: bytes, dropped: dropped}, %{hook: hook})
  end

  @spec pending(non_neg_integer()) :: :ok
  def pending(count), do: execute([:hub, :pending], %{count: count})

  def in_flight_sends(count), do: execute([:hub, :sends], %{count: count})

  def rejection(hook, reason),
    do: execute([:hub, :delivery, :rejected], %{count: 1}, %{hook: hook, reason: reason})

  def response(duration, hook),
    do: execute([:hub, :response, :stop], %{duration: duration}, %{hook: hook})

  @spec send(non_neg_integer(), atom(), atom()) :: :ok
  def send(duration, kind, outcome) do
    execute([:hub, :send, :stop], %{duration: duration}, %{kind: kind, outcome: outcome})
  end

  @spec status_snapshot(non_neg_integer(), non_neg_integer(), atom()) :: :ok
  def status_snapshot(duration, bytes, scope) do
    execute(
      [:hub, :status, :snapshot, :stop],
      %{duration: duration, bytes: bytes},
      %{scope: scope}
    )
  end

  @spec reload(non_neg_integer(), atom(), atom()) :: :ok
  def reload(duration, action, outcome) do
    execute(
      [:hub, :reload, :stop],
      %{duration: duration},
      %{action: action, outcome: outcome}
    )
  end

  @spec lookup(non_neg_integer(), atom()) :: :ok
  def lookup(duration, outcome) do
    execute([:hub, :lookup, :stop], %{duration: duration}, %{outcome: outcome})
  end

  @spec poll(non_neg_integer(), atom()) :: :ok
  def poll(duration, outcome) do
    execute([:telegram, :poll, :stop], %{duration: duration}, %{outcome: outcome})
  end

  @spec redelivery(atom()) :: :ok
  def redelivery(transport) do
    execute([:hub, :delivery, :redelivery], %{count: 1}, %{transport: transport})
  end

  @spec listener_drop(String.t(), atom()) :: :ok
  def listener_drop(hook, reason) do
    execute([:hub, :listener, :drop], %{count: 1}, %{hook: hook, reason: reason})
  end

  defp execute(event, measurements, metadata \\ %{}) do
    :telemetry.execute([:exiron | event], measurements, metadata)
  end
end
