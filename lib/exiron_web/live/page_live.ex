defmodule ExironWeb.PageLive do
  use ExironWeb, :live_view

  alias Exiron.Hub
  alias ExironWeb.PageLive.Components
  alias ExironWeb.StatusSync

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> StatusSync.subscribe()
     |> assign(:page_title, "Overview")
     |> StatusSync.assign_snapshot(Hub.status(), stream_specs(), status_sync_options())}
  end

  @impl true
  def handle_info({kind, _payload} = message, socket)
      when kind in [:hub_status, :hub_status_delta] do
    {:noreply, StatusSync.handle(socket, message, stream_specs(), status_sync_options())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:overview}>
      <div id="exiron-overview" class="space-y-5">
        <Components.overview exiron={@exiron} counts={@counts} />
        <Components.activity streams={@streams} counts={@counts} />
      </div>
    </Layouts.app>
    """
  end

  defp stream_specs do
    [
      hooks: &"exiron-hook-#{&1.name}",
      routes: &"exiron-route-#{&1.id}",
      events: &"exiron-event-#{&1.id}",
      send_failures: &"exiron-send-failure-#{&1.id}",
      overload_events: &"exiron-overload-event-#{&1.id}",
      client_events: &"exiron-client-event-#{&1.id}"
    ]
  end

  defp status_sync_options do
    [
      metrics: fn status ->
        %{
          connected: Enum.count(status.hooks, & &1.connected),
          queued: Enum.sum_by(status.hooks, & &1.queued)
        }
      end,
      metric_keys: [:connected, :queued]
    ]
  end
end
