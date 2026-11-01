defmodule ExironWeb.StatusSync do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, stream: 4]

  alias Exiron.Hub
  alias Exiron.Hub.StatusDelta
  alias ExironWeb.StatusStreams

  def subscribe(socket) do
    if connected?(socket) do
      :ok = Hub.subscribe_status()
    end

    socket
  end

  def handle(socket, message, stream_specs, opts \\ [])

  def handle(socket, {:hub_status, status}, stream_specs, opts) do
    assign_snapshot(socket, status, stream_specs, opts)
  end

  def handle(socket, {:hub_status_delta, delta}, stream_specs, opts) do
    if socket.assigns.status_revision == delta.base_revision do
      apply_delta(socket, delta, stream_specs, opts)
    else
      assign_snapshot(socket, Hub.status(), stream_specs, opts)
    end
  end

  def assign_snapshot(socket, status, stream_specs, opts \\ []) do
    counts =
      stream_specs
      |> Map.new(fn {name, _dom_id} -> {name, status |> Map.fetch!(name) |> length()} end)
      |> Map.merge(snapshot_metrics(status, opts))

    Enum.reduce(stream_specs, assign_snapshot_values(socket, status, counts), fn
      {name, dom_id}, socket ->
        stream(socket, name, Map.fetch!(status, name), reset: true, dom_id: dom_id)
    end)
  end

  def apply_delta(socket, delta, stream_specs, opts \\ []) do
    counts =
      socket.assigns.counts
      |> update_counts(delta.collections)
      |> Map.merge(delta_metrics(delta, opts))

    socket = assign_delta_values(socket, delta, counts)

    Enum.reduce(stream_specs, socket, fn {name, _dom_id}, socket ->
      case Map.fetch(delta.collections, name) do
        {:ok, collection_delta} -> StatusStreams.apply_delta(socket, name, collection_delta)
        :error -> socket
      end
    end)
  end

  def update_counts(counts, collections) do
    Enum.reduce(collections, counts, fn {name, collection_delta}, counts ->
      if Map.has_key?(counts, name) do
        Map.put(counts, name, collection_delta.count)
      else
        counts
      end
    end)
  end

  defp assign_snapshot_values(socket, status, counts) do
    socket
    |> assign(:status_revision, status.revision)
    |> assign(:exiron, Map.drop(status, StatusDelta.collection_keys()))
    |> assign(:counts, counts)
  end

  defp assign_delta_values(socket, delta, counts) do
    socket
    |> assign(:status_revision, delta.revision)
    |> assign(
      :exiron,
      socket.assigns.exiron |> Map.merge(delta.values) |> Map.put(:revision, delta.revision)
    )
    |> assign(:counts, counts)
  end

  defp snapshot_metrics(status, opts) do
    case Keyword.get(opts, :metrics) do
      metrics when is_function(metrics, 1) -> metrics.(status)
      _metrics -> %{}
    end
  end

  defp delta_metrics(delta, opts) do
    opts
    |> Keyword.get(:metric_keys, [])
    |> Map.new(&{&1, Map.fetch!(delta.metrics, &1)})
  end
end
