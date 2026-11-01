defmodule ExironWeb.MonitorLive do
  use ExironWeb, :live_view

  alias Exiron.Hub
  alias ExironWeb.MonitorLive.{ActivityPanels, ChatNetwork, Components, DeliveryHealth}
  alias ExironWeb.MonitorLive.RequestActivity
  alias ExironWeb.StatusSync

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Hub.subscribe_traces()

    {:ok,
     socket
     |> StatusSync.subscribe()
     |> assign(:page_title, "Monitor")
     |> assign(:monitor_link, ~p"/monitor")
     |> assign(:live_paused?, false)
     |> assign(:drain, Hub.drain_status())
     |> assign(:drain_form, to_form(%{"timeout_seconds" => "60"}, as: :drain))
     |> assign(
       :activity_refresh_timer,
       if(connected?(socket), do: Process.send_after(self(), :refresh_request_activity, 5_000))
     )
     |> assign(:paused_traces, nil)
     |> assign_monitor_snapshot(Hub.status())
     |> RequestActivity.initialize()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = Map.filter(params, fn {_, value} -> is_binary(value) end)
    socket = RequestActivity.filter(socket, Map.take(params, RequestActivity.filter_keys()))
    id = params |> Map.get("inspect", "") |> String.slice(0, 200)

    trace =
      if id != "" do
        if socket.assigns.live_paused?,
          do: Enum.find(socket.assigns.paused_traces || [], &(&1.id == id)),
          else: Hub.request_trace(id)
      end

    selected =
      if trace &&
           (Map.get(params, "hook", "") == "" or trace.hook == params["hook"]),
         do: id

    delivery_id = params |> Map.get("delivery", "") |> String.slice(0, 200)

    diagnostic =
      if is_nil(selected) and delivery_id != "",
        do:
          Enum.find(Map.values(socket.assigns.failure_deliveries), fn value ->
            value.id == delivery_id and
              (Map.get(params, "hook", "") == "" or value.hook == params["hook"])
          end)

    socket = socket |> assign(:manual_delivery, diagnostic) |> assign(:selected_request, selected)

    socket =
      if delivery_id != "" and is_nil(diagnostic) and is_nil(selected),
        do:
          put_flash(
            socket,
            :error,
            "This delivery diagnostic is no longer retained for the selected hook."
          ),
        else: socket

    socket =
      if id != "" and is_nil(selected),
        do:
          put_flash(socket, :error, "This request is no longer retained for the selected hook."),
        else: socket

    socket = RequestActivity.refresh(socket, socket.assigns.paused_traces)

    link =
      view_path(socket.assigns.activity_filters,
        inspect: selected,
        delivery: diagnostic && diagnostic.id
      )

    {:noreply, assign(socket, :monitor_link, link)}
  end

  @impl true
  def handle_info({kind, _payload} = message, socket)
      when kind in [:hub_status, :hub_status_delta] do
    socket = assign(socket, :drain, Hub.drain_status())

    if socket.assigns.live_paused? do
      {:noreply, socket}
    else
      {:noreply, socket |> sync_monitor(message) |> RequestActivity.refresh()}
    end
  end

  def handle_info(:request_traces_changed, socket) do
    {:noreply, if(socket.assigns.live_paused?, do: socket, else: RequestActivity.refresh(socket))}
  end

  def handle_info(:refresh_request_activity, socket) do
    if is_reference(socket.assigns.activity_refresh_timer),
      do: Process.cancel_timer(socket.assigns.activity_refresh_timer)

    socket = assign(socket, :drain, Hub.drain_status())

    socket =
      assign(
        socket,
        :activity_refresh_timer,
        Process.send_after(self(), :refresh_request_activity, 5_000)
      )

    {:noreply,
     if(socket.assigns.live_paused?,
       do: socket,
       else: socket |> refresh_hook_presence() |> RequestActivity.refresh()
     )}
  end

  defp refresh_hook_presence(socket) do
    suppression = Exiron.Hub.Telegram.SendCoordinator.snapshot()

    socket
    |> stream(:hooks, Hub.hook_statuses(), reset: true, dom_id: &"delivery-hook-#{&1.name}")
    |> stream(:suppressed_bots, suppression.records,
      reset: true,
      dom_id: &"suppressed-bot-#{&1.id}"
    )
    |> assign(
      :exiron,
      Map.put(socket.assigns.exiron, :telegram_suppression, Map.delete(suppression, :records))
    )
  end

  @impl true
  def handle_event("start_drain", %{"drain" => params}, socket) do
    result =
      with :ok <- drain_controls_allowed(socket),
           {seconds, ""} <- Integer.parse(params["timeout_seconds"] || ""),
           {:ok, _} <- Hub.start_drain(timeout_ms: seconds * 1000),
           do: :ok

    socket =
      if result == :ok,
        do: socket,
        else:
          put_flash(socket, :error, "Use live updates and a timeout between 1 and 3600 seconds.")

    {:noreply, assign(socket, :drain, Hub.drain_status())}
  end

  def handle_event("resume_intake", _params, socket) do
    socket =
      case drain_controls_allowed(socket) do
        :ok ->
          :ok = Hub.resume_intake()
          socket

        _ ->
          put_flash(socket, :error, "Resume live updates before using drain controls.")
      end

    {:noreply, assign(socket, :drain, Hub.drain_status())}
  end

  def handle_event("filter_activity", %{"activity" => params}, socket),
    do: {:noreply, push_patch(socket, to: view_path(params), replace: true)}

  def handle_event("inspect_request", %{"id" => id}, socket),
    do:
      {:noreply, push_patch(socket, to: view_path(socket.assigns.activity_filters, inspect: id))}

  def handle_event("inspect_delivery", %{"id" => id}, socket),
    do:
      {:noreply, push_patch(socket, to: view_path(socket.assigns.activity_filters, delivery: id))}

  def handle_event("close_request", _params, socket),
    do: {:noreply, push_patch(socket, to: view_path(socket.assigns.activity_filters))}

  def handle_event("cancel_request", %{"id" => id}, socket) do
    cond do
      socket.assigns.live_paused? ->
        {:noreply, put_flash(socket, :error, "Resume live updates before cancelling a request.")}

      is_nil(socket.assigns.current_scope) or id != socket.assigns.selected_request ->
        {:noreply, put_flash(socket, :error, "Inspect the request before cancelling it.")}

      true ->
        socket =
          case Hub.cancel_from_monitor(id) do
            {:ok, _result} ->
              socket

            {:error, :request_not_found} ->
              put_flash(
                socket,
                :error,
                "This request is already closed or no longer retained. Nothing was cancelled."
              )
          end

        {:noreply, socket |> assign_monitor_snapshot(Hub.status()) |> RequestActivity.refresh()}
    end
  end

  def handle_event("toggle_live", _params, socket) do
    socket =
      if socket.assigns.live_paused? do
        socket
        |> assign(:live_paused?, false)
        |> assign(:paused_traces, nil)
        |> assign_monitor_snapshot(Hub.status())
        |> RequestActivity.refresh()
      else
        # One bounded snapshot supports inspection while all live panels pause.
        traces = Hub.request_trace_snapshot()

        socket
        |> assign(:live_paused?, true)
        |> assign(:paused_traces, traces)
        |> RequestActivity.refresh(traces)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:monitor}>
      <section id="exiron-monitor" class="space-y-5">
        <div class="ex-monitor-hero">
          <div class="relative z-10 grid grid-cols-2 lg:grid-cols-4">
            <Components.monitor_stat
              label="Chats"
              value={@counts.chats}
              detail="configured"
              icon="hero-chat-bubble-left-right-micro"
            />
            <Components.monitor_stat
              label="Group changes"
              value={@counts.membership_events}
              detail="recent"
              icon="hero-user-group-micro"
            />
            <Components.monitor_stat
              label="Send issues"
              value={@counts.send_failures}
              detail={if(@counts.send_failures == 0, do: "clear", else: "needs review")}
              icon={
                if(@counts.send_failures == 0,
                  do: "hero-check-circle-micro",
                  else: "hero-exclamation-triangle-micro"
                )
              }
              alert={@counts.send_failures > 0}
            />
            <Components.monitor_stat
              id="exiron-monitor-polling-summary"
              label="Polling network"
              value={if(@exiron.telegram_polling, do: "Active", else: "Offline")}
              detail={if(@exiron.telegram_polling, do: "all systems", else: "unavailable")}
              icon={
                if(@exiron.telegram_polling, do: "hero-signal-micro", else: "hero-no-symbol-micro")
              }
              alert={!@exiron.telegram_polling}
              live={@exiron.telegram_polling}
            />
          </div>
        </div>

        <ExironWeb.MonitorLive.DrainPanel.panel
          drain={@drain}
          form={@drain_form}
          paused?={@live_paused?}
          enabled?={@exiron.enabled}
        />
        <DeliveryHealth.delivery_health
          health={@exiron.delivery_health}
          capacity={@exiron.buffer_capacity}
          send_capacity={@exiron.send_capacity}
          streams={@streams}
        />
        <ExironWeb.MonitorLive.BotSuppression.panel
          summary={@exiron.telegram_suppression}
          streams={@streams}
        />
        <RequestActivity.activity
          streams={@streams}
          form={@activity_form}
          hook_options={@activity_hook_options}
          chat_options={@activity_chat_options}
          total={@trace_count}
          matching={@matching_trace_count}
          selected={@selected_trace}
          delivery={@selected_delivery}
          permalink={@monitor_link}
          paused?={@live_paused?}
        />
        <ChatNetwork.chat_network streams={@streams} count={@counts.chats} />
        <ActivityPanels.activity_panels streams={@streams} counts={@counts} />
      </section>
    </Layouts.app>
    """
  end

  defp drain_controls_allowed(socket) do
    if socket.assigns.current_scope && !socket.assigns.live_paused?, do: :ok, else: :error
  end

  defp view_path(filters, selection \\ []) do
    params =
      filters
      |> RequestActivity.normalize_filters()
      |> Enum.reject(fn {_key, value} -> value == "" end)

    selected =
      for key <- [:inspect, :delivery],
          value = selection[key],
          is_binary(value) and value != "",
          do: {Atom.to_string(key), String.slice(value, 0, 200)}

    ~p"/monitor?#{Enum.sort(params ++ selected)}"
  end

  defp assign_monitor_snapshot(socket, status) do
    socket
    |> assign(:activity_destinations, RequestActivity.destinations(status))
    |> assign(:failure_deliveries, failure_index(status.send_failures))
    |> StatusSync.assign_snapshot(status, stream_specs())
  end

  defp failure_index(items),
    do:
      Map.new(
        Enum.flat_map(items, fn item ->
          if Map.get(item, :delivery),
            do: [{item.id, Map.put(item.delivery, :hook, item.hook)}],
            else: []
        end)
      )

  defp sync_monitor(socket, {:hub_status, status}), do: assign_monitor_snapshot(socket, status)

  defp sync_monitor(socket, {:hub_status_delta, delta} = message) do
    if socket.assigns.status_revision == delta.base_revision do
      index =
        case Map.get(delta.collections, :send_failures) do
          nil ->
            socket.assigns.failure_deliveries

          %{reset: items} ->
            failure_index(items)

          %{deletes: deletes, upserts: upserts} ->
            socket.assigns.failure_deliveries
            |> Map.drop(Enum.map(deletes, & &1.id))
            |> Map.merge(failure_index(Enum.map(upserts, & &1.item)))
        end

      socket
      |> assign(
        :activity_destinations,
        RequestActivity.update_destinations(
          socket.assigns.activity_destinations,
          delta.collections
        )
      )
      |> assign(:failure_deliveries, index)
      |> StatusSync.handle(message, stream_specs())
    else
      assign_monitor_snapshot(socket, Hub.status())
    end
  end

  defp stream_specs do
    [
      hooks: &"delivery-hook-#{&1.name}",
      suppressed_bots: &"suppressed-bot-#{&1.id}",
      chats: &"exiron-monitor-chat-#{&1.id}",
      membership_events: &"exiron-monitor-membership-event-#{&1.id}",
      send_failures: &"exiron-monitor-send-failure-#{&1.id}"
    ]
  end
end
