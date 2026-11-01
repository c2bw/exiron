defmodule Exiron.Hub.StatusPublisher do
  @moduledoc false

  alias Exiron.Hub.{State, Status, StatusDelta}

  @version_file Path.expand("../../../VERSION", __DIR__)
  @external_resource @version_file
  @version @version_file |> File.read!() |> String.trim()
  @topic "hub:status"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Exiron.PubSub, @topic)
  end

  @spec snapshot(State.t()) :: map()
  def snapshot(%State{} = state) do
    Status.snapshot(state, @version)
  end

  @spec initialize(State.t()) :: State.t()
  def initialize(%State{} = state) do
    %{state | publication: %{state.publication | snapshot: snapshot(state)}}
  end

  @spec publish(State.t()) :: State.t()
  def publish(%State{} = state) do
    state = publish_traces(state)
    current = snapshot(state)
    emit_gauges(current, state.publication.snapshot)

    case state.publication.snapshot do
      nil ->
        state = put_revision(state, state.publication.revision + 1)
        snapshot = snapshot_revision(current, state.publication.revision)
        broadcast({:hub_status, snapshot})
        put_snapshot(state, snapshot)

      previous ->
        publish_delta(state, previous, current)
    end
  end

  defp publish_traces(state) do
    if state.activity.trace_revision != state.publication.trace_revision do
      Phoenix.PubSub.broadcast(Exiron.PubSub, "hub:traces", :request_traces_changed)
      put_in(state.publication.trace_revision, state.activity.trace_revision)
    else
      state
    end
  end

  defp emit_gauges(current, previous) do
    previous_hooks = Map.new((previous || %{}) |> Map.get(:hooks, []), &{&1.name, &1})
    current_hooks = Map.new(current.hooks, &{&1.name, &1})

    for {name, hook} <- current_hooks, Map.get(previous_hooks, name) != hook do
      Exiron.Telemetry.queue(hook.health.queued, hook.health.queued_bytes, 0, name)
    end

    for {name, _hook} <- previous_hooks, not Map.has_key?(current_hooks, name) do
      Exiron.Telemetry.queue(0, 0, 0, name)
    end

    Exiron.Telemetry.pending(current.delivery_health.pending)
    Exiron.Telemetry.in_flight_sends(current.delivery_health.in_flight_sends)
  end

  defp publish_delta(state, previous, current) do
    case StatusDelta.between(previous, current) do
      :unchanged ->
        state

      {:changed, delta} ->
        revision = state.publication.revision + 1

        delta =
          Map.merge(delta, %{base_revision: state.publication.revision, revision: revision})

        broadcast({:hub_status_delta, delta})

        state = put_revision(state, revision)
        put_snapshot(state, snapshot_revision(current, revision))
    end
  end

  # Disabled snapshots deliberately retain the public revision zero.
  defp snapshot_revision(%{enabled: true} = snapshot, revision),
    do: %{snapshot | revision: revision}

  defp snapshot_revision(snapshot, _revision), do: snapshot

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Exiron.PubSub, @topic, message)
  end

  defp put_revision(state, revision),
    do: %{state | publication: %{state.publication | revision: revision}}

  defp put_snapshot(state, snapshot),
    do: %{state | publication: %{state.publication | snapshot: snapshot}}
end
