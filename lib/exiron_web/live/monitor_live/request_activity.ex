defmodule ExironWeb.MonitorLive.RequestActivity do
  @moduledoc false
  use ExironWeb, :html
  import Phoenix.LiveView, only: [stream: 4]

  alias Exiron.Hub
  alias ExironWeb.MonitorLive.ClientConnection

  @ranges [{"All retained history", ""}, {"Last 5 minutes", "5m"}, {"Last hour", "1h"}]
  @filter_keys ~w(hook chat client request outcome range)
  @outcomes ~w(queued delivered awaiting_response handler_retrying handler_exhausted sending completed send_failed failed expired cancelled delivery_unknown)
  def filter_keys, do: @filter_keys

  # Keep only selector metadata; LiveView streams own the full status rows.
  def destinations(status),
    do: Map.new([:hooks, :chats], &{&1, destination_index(&1, Map.fetch!(status, &1))})

  def update_destinations(destinations, collections) do
    Enum.reduce([:hooks, :chats], destinations, fn kind, destinations ->
      case Map.get(collections, kind) do
        nil ->
          destinations

        %{reset: items} ->
          Map.put(destinations, kind, destination_index(kind, items))

        %{deletes: deletes, upserts: upserts} ->
          removed = Enum.map(deletes, &destination_key(kind, &1))

          updated =
            destinations[kind]
            |> Map.drop(removed)
            |> Map.merge(destination_index(kind, Enum.map(upserts, & &1.item)))

          Map.put(destinations, kind, updated)
      end
    end)
  end

  defp destination_key(:hooks, item), do: item.name
  defp destination_key(:chats, item), do: item.id

  defp destination_index(kind, items) do
    fields = if kind == :hooks, do: [:name], else: [:id, :aliases]
    Map.new(items, &{destination_key(kind, &1), Map.take(&1, fields)})
  end

  def initialize(socket) do
    socket
    |> assign(:activity_filters, normalize_filters(%{}))
    |> assign(:activity_form, to_form(normalize_filters(%{}), as: :activity))
    |> assign(:selected_request, nil)
    |> assign(:selected_trace, nil)
    |> assign(:manual_delivery, nil)
    |> assign(:selected_delivery, nil)
    |> stream(:delivery_parts, [], dom_id: &"delivery-part-#{&1.id}")
    |> stream(:trace_steps, [], dom_id: &"trace-step-#{&1.id}")
  end

  # Assign filters first; refresh streams once after the final selection is known.
  # Multiple resets before a render retain inserts from earlier resets.
  def filter(socket, params) do
    params = normalize_filters(params)

    socket
    |> assign(:activity_filters, params)
    |> assign(:activity_form, to_form(params, as: :activity))
  end

  def refresh(socket, traces \\ nil) do
    captured? = not is_nil(traces)
    traces = traces || Hub.request_traces()
    {hook_options, chat_options} = filter_options(socket.assigns.activity_destinations, traces)

    params =
      socket.assigns.activity_filters
      |> valid_choice("hook", hook_options)
      |> valid_choice("chat", chat_options)
      |> valid_choice("range", @ranges)

    matching = traces |> Enum.filter(&matches?(&1, params)) |> Enum.map(&timing/1)

    selected =
      cond do
        is_nil(socket.assigns.selected_request) -> nil
        captured? -> Enum.find(traces, &(&1.id == socket.assigns.selected_request))
        true -> Hub.request_trace(socket.assigns.selected_request)
      end

    diagnostic = (selected && Map.get(selected, :delivery)) || socket.assigns.manual_delivery

    socket
    |> assign(:activity_filters, params)
    |> assign(:activity_form, to_form(params, as: :activity))
    |> assign(:activity_hook_options, hook_options)
    |> assign(:activity_chat_options, chat_options)
    |> assign(:selected_delivery, diagnostic)
    |> stream(:delivery_parts, if(diagnostic, do: diagnostic.parts, else: []), reset: true)
    |> assign(:trace_count, length(traces))
    |> assign(:matching_trace_count, length(matching))
    |> assign(:selected_trace, selected && selected |> Map.delete(:steps) |> timing())
    |> stream(:request_traces, matching,
      reset: true,
      dom_id: &"request-trace-#{&1.id}"
    )
    |> stream(:trace_steps, if(selected, do: selected.steps, else: []), reset: true)
  end

  def normalize_filters(params) do
    values =
      Map.new(@filter_keys, fn key ->
        value = Map.get(params, key, "")
        {key, if(is_binary(value), do: String.slice(value, 0, 200), else: "")}
      end)

    values
    |> Map.update!("outcome", &if(&1 in ["" | @outcomes], do: &1, else: ""))
    |> Map.update!("range", &if(&1 in ["", "5m", "1h"], do: &1, else: ""))
  end

  defp filter_options(status, traces) do
    hooks =
      (Enum.map(Map.values(status.hooks), & &1.name) ++ Enum.map(traces, & &1.hook))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort_by(&String.downcase/1)
      |> Enum.map(&{&1, &1})

    chats =
      Map.new(Map.values(status.chats), fn chat ->
        aliases = chat.aliases |> Enum.sort() |> Enum.join(", ")
        label = if aliases == "", do: to_string(chat.id), else: "#{aliases} (#{chat.id})"
        {chat.id, label}
      end)

    chats =
      Enum.reduce(traces, chats, fn trace, chats ->
        Map.put_new(chats, trace.chat_id, to_string(trace.chat_id))
      end)

    chats =
      chats
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, label} -> {label, to_string(id)} end)

    {[{"All hooks", ""} | hooks], [{"All chats", ""} | chats]}
  end

  defp valid_choice(params, key, options) do
    if Enum.any?(options, fn {_label, value} -> value == params[key] end),
      do: params,
      else: Map.put(params, key, "")
  end

  defp matches?(trace, params) do
    in_range?(trace.age_ms, params["range"]) and
      Enum.all?(
        [
          {"hook", trace.hook},
          {"chat", trace.chat_id}
        ],
        fn {key, value} -> params[key] == "" or params[key] == to_string(value) end
      ) and
      matches_outcome?(trace, params["outcome"]) and
      Enum.all?([{"client", trace.client_id}, {"request", trace.id}], fn {key, value} ->
        String.contains?(
          String.downcase(to_string(value)),
          String.downcase(String.trim(params[key]))
        )
      end)
  end

  defp matches_outcome?(_trace, ""), do: true

  defp matches_outcome?(trace, "handler_retrying"),
    do: get_in(trace, [:handler, "state"]) == "retrying"

  defp matches_outcome?(trace, "handler_exhausted"),
    do: get_in(trace, [:handler, "state"]) == "exhausted"

  defp matches_outcome?(trace, outcome), do: to_string(trace.status) == outcome

  defp in_range?(age, "5m"), do: age <= 300_000
  defp in_range?(age, "1h"), do: age <= 3_600_000
  defp in_range?(_age, _range), do: true

  defp timing(trace) do
    long_wait? =
      case trace.wait_phase do
        phase when phase in [:client_queue, :client, :retry] -> trace.waiting_ms >= 60_000
        :telegram -> trace.waiting_ms >= 15_000
        _ -> false
      end

    attention =
      cond do
        trace.pending? and is_integer(trace.expires_in_ms) and trace.expires_in_ms <= 30_000 ->
          :expiring

        (trace.wait_phase != :telegram and trace.client_presence) &&
            trace.client_presence.state == "websocket_disconnected" ->
          :client_disconnected

        trace.pending? and get_in(trace, [:handler, "state"]) == "exhausted" ->
          :handler_failed

        long_wait? ->
          :long_wait

        true ->
          nil
      end

    Map.put(trace, :attention, attention)
  end

  attr :id, :string, required: true
  attr :report, :map, default: nil

  defp handler_report(assigns) do
    ~H"""
    <p
      :if={@report}
      id={@id}
      data-state={@report["state"]}
      class="my-2 max-w-lg rounded-lg border border-base-300 bg-base-200/60 px-2 py-1.5 text-[11px] text-base-content/75"
    >
      Last client report: <span class="font-semibold">{handler_label(@report["state"])}</span>
      · attempt {@report["attempt"]}/{@report["max_attempts"]}
      <span :if={@report["category"]}> · {label_string(@report["category"])}</span>
    </p>
    """
  end

  defp handler_label("retrying"), do: "Handler retrying"
  defp handler_label("exhausted"), do: "Handler retries exhausted"
  defp handler_label("recovered"), do: "Handler recovered"

  defp wait_label(:client_queue), do: "Waiting for client pickup"
  defp wait_label(:client), do: "Waiting for client response"
  defp wait_label(:handler_retry), do: "Client reported a handler retry"
  defp wait_label(:handler_failed), do: "Client reported exhausted retries"
  defp wait_label(:telegram), do: "Waiting for Telegram delivery"
  defp wait_label(:retry), do: "Waiting for response retry"
  defp attention_label(:handler_failed), do: "Handler retries exhausted"
  defp attention_label(:expiring), do: "Expiring soon"
  defp attention_label(:long_wait), do: "Long wait"
  defp attention_label(:client_disconnected), do: "Client disconnected"

  defp duration(ms) do
    seconds = div(ms, 1000)

    cond do
      seconds < 1 -> "<1s"
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  attr :id, :string, required: true
  attr :trace, :map, required: true

  defp request_timing(assigns) do
    ~H"""
    <div id={@id} class="space-y-1 text-xs text-base-content/65">
      <p>
        <span id={@id <> "-age"}>Age {duration(@trace.age_ms)}</span>
        <span
          :if={@trace.attention}
          id={@id <> "-attention"}
          class="ml-2 inline-flex rounded bg-amber-500/15 px-2 py-0.5 font-semibold text-amber-800 dark:text-amber-200"
        >
          {attention_label(@trace.attention)}
        </span>
      </p>
      <p :if={@trace.wait_phase} id={@id <> "-wait"} data-phase={@trace.wait_phase}>
        {wait_label(@trace.wait_phase)} · {duration(@trace.waiting_ms)}
      </p>
      <p :if={is_integer(@trace.expires_in_ms)} id={@id <> "-expiry"}>
        {if @trace.expires_in_ms == 0,
          do: "Expiry due",
          else: "Expires in #{duration(@trace.expires_in_ms)}"}
      </p>
      <p class="text-[11px] text-base-content/50">
        Last event +{@trace.elapsed_ms} ms · deliveries: {@trace.deliveries}
      </p>
    </div>
    """
  end

  defp delivery_label("not_started"), do: "Not started"
  defp delivery_label("partial"), do: "Partially delivered"
  defp delivery_label("unknown"), do: "Uncertain"

  attr :trace, :map, required: true
  attr :paused?, :boolean, required: true

  defp cancellation_controls(assigns) do
    assigns =
      assign(assigns, :progress, assigns.trace.cancellation || assigns.trace.delivery_progress)

    ~H"""
    <section
      :if={@progress}
      id="exiron-request-cancellation"
      class="mt-3 rounded-lg border border-base-300/70 p-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0 space-y-1 text-xs">
          <h4 class="font-semibold">
            {if @trace.cancellation, do: "Remaining work cancelled", else: "Cancel remaining work"}
          </h4>
          <p id="exiron-cancellation-delivery" data-delivery-status={@progress.delivery_status}>
            Telegram delivery: {delivery_label(@progress.delivery_status)}
          </p>
          <p id="exiron-cancellation-message-ids" class="break-all text-base-content/60">
            Confirmed Telegram IDs: {if @progress.message_ids == [],
              do: "None confirmed",
              else: Enum.join(@progress.message_ids, ", ")}
          </p>
          <p class="text-base-content/60">
            Stops remaining sends and further response updates. Messages Telegram already accepted cannot be undone.
          </p>
        </div>
        <button
          :if={@trace.pending?}
          id="exiron-cancel-request"
          type="button"
          phx-click="cancel_request"
          phx-value-id={@trace.id}
          phx-disable-with="Cancelling…"
          disabled={@paused?}
          class="inline-flex items-center gap-2 rounded-lg border border-red-500/30 bg-red-500/5 px-3 py-2 text-xs font-semibold text-red-700 transition hover:bg-red-500/10 disabled:cursor-not-allowed disabled:opacity-50 dark:text-red-300"
        >
          <.icon name="hero-stop-circle-micro" class="size-4" /> Cancel request
        </button>
      </div>
      <p
        :if={@paused? and @trace.pending?}
        id="exiron-cancel-paused"
        class="mt-2 text-xs text-base-content/60"
      >
        Resume live updates to cancel this request.
      </p>
      <p
        :if={@trace.cancellation}
        id="exiron-cancellation-result"
        role="status"
        class="mt-2 text-xs font-semibold"
      >
        Request cancelled. {if @progress.delivery_status == "unknown",
          do: "Delivery remains uncertain; inspect Telegram before sending anything again.",
          else: "No further response updates will be accepted."}
      </p>
    </section>
    """
  end

  attr :streams, :any, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :hook_options, :list, required: true
  attr :chat_options, :list, required: true
  attr :total, :integer, required: true
  attr :matching, :integer, required: true
  attr :selected, :any, default: nil
  attr :paused?, :boolean, default: false
  attr :delivery, :map, default: nil
  attr :permalink, :string, default: "/monitor"

  def activity(assigns) do
    assigns = assign(assigns, :ranges, @ranges)

    ~H"""
    <section id="exiron-request-activity" class="ex-panel min-w-0 overflow-hidden">
      <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300/70 px-4 py-4">
        <div class="min-w-0">
          <h2 id="exiron-request-activity-title" class="text-sm font-bold">Request activity</h2>
          <p class="mt-1 text-xs text-base-content/60">
            {@matching} matching requests · {@total} of 500 retained requests
          </p>
          <p class="mt-1 text-xs text-base-content/50">
            Timing refreshes every 5 seconds · in-memory history · message bodies omitted
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.link
            id="exiron-monitor-permalink"
            href={@permalink}
            class="ex-action-button"
            title="Bookmark this address or copy the link to share this view"
          ><.icon name="hero-link-micro" class="size-4" /> Link to this view</.link>
          <button
            id="exiron-toggle-live"
            type="button"
            phx-click="toggle_live"
            aria-pressed={@paused?}
            class="inline-flex items-center gap-2 rounded-lg border border-base-300 px-3 py-2 text-xs font-bold transition hover:bg-base-200"
          >
            <.icon
              name={if(@paused?, do: "hero-play-micro", else: "hero-pause-micro")}
              class="size-4"
            />
            {if(@paused?, do: "Resume live updates", else: "Pause live updates")}
          </button>
        </div>
      </div>
      <p
        :if={@paused?}
        id="exiron-live-paused"
        class="bg-amber-500/10 px-4 py-2 text-xs text-amber-800 dark:text-amber-200"
      >
        Live updates paused. Filters and details use the captured snapshot. Resume to see current activity.
      </p>
      <.form
        for={@form}
        id="exiron-activity-filters"
        phx-change="filter_activity"
        phx-submit="filter_activity"
        class="grid gap-3 border-b border-base-300/70 p-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6"
      >
        <.input
          id="exiron-activity-hook"
          field={@form[:hook]}
          type="select"
          label="Hook"
          options={@hook_options}
        />
        <.input
          id="exiron-activity-chat"
          field={@form[:chat]}
          type="select"
          label="Chat"
          options={@chat_options}
        />
        <.input
          id="exiron-activity-range"
          field={@form[:range]}
          type="select"
          label="Received"
          options={@ranges}
        />
        <.input field={@form[:client]} label="Client ID" placeholder="Any client" phx-debounce="250" />
        <.input
          field={@form[:request]}
          label="Request ID"
          placeholder="Find a request"
          phx-debounce="250"
        />
        <.input
          field={@form[:outcome]}
          type="select"
          label="Outcome"
          options={[
            {"Any outcome", ""},
            {"Queued", "queued"},
            {"Delivered", "delivered"},
            {"Awaiting response", "awaiting_response"},
            {"Last handler report: retrying", "handler_retrying"},
            {"Last handler report: exhausted", "handler_exhausted"},
            {"Sending", "sending"},
            {"Completed", "completed"},
            {"Send failed; inspect delivery details", "send_failed"},
            {"Failed", "failed"},
            {"Expired", "expired"},
            {"Cancelled", "cancelled"},
            {"Delivery unknown", "delivery_unknown"}
          ]}
        />
      </.form>
      <div
        id="exiron-request-scroll"
        phx-hook="RequestActivityScroll"
        data-filter-key={Jason.encode!(@form.params)}
        tabindex="0"
        role="region"
        aria-labelledby="exiron-request-activity-title"
        aria-describedby="exiron-request-scroll-hint"
        class="ex-request-scroll min-w-0 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-primary"
      >
        <div
          id="exiron-request-traces"
          phx-update="stream"
          class="divide-y divide-base-300/60"
        >
          <p id="exiron-traces-empty" class="hidden px-4 py-6 text-sm text-base-content/50 only:block">
            No retained requests match these filters.
          </p>
          <article
            :for={{id, trace} <- @streams.request_traces}
            id={id}
            data-outcome={trace.status}
            data-handler-state={get_in(trace, [:handler, "state"])}
            data-attention={trace.attention}
            class={[
              "flex min-w-0 flex-wrap items-center justify-between gap-3 px-4 py-3",
              trace.attention && "bg-amber-500/5"
            ]}
          >
            <div class="min-w-0">
              <button
                id={id <> "-inspect"}
                type="button"
                phx-click="inspect_request"
                phx-value-id={trace.id}
                class="break-all text-left font-mono text-xs font-bold text-primary underline-offset-2 transition hover:underline"
              >{trace.id}</button>
              <p class="mt-1 break-all text-xs text-base-content/60">
                {trace.hook} · chat {trace.chat_id} · client {trace.client_id || "not delivered"}
              </p>
              <p class="mt-1 text-[11px] text-base-content/50">
                Received
                <time id={id <> "-received"} datetime={DateTime.to_iso8601(trace.at)}>{Calendar.strftime(
                  trace.at,
                  "%Y-%m-%d %H:%M:%S UTC"
                )}</time>
              </p>
              <p
                :if={trace.client_presence}
                id={id <> "-client-state"}
                data-state={trace.client_presence.state}
                class="mt-1 text-[11px] text-base-content/60"
              >
                {ClientConnection.label(trace.client_presence.state)}
              </p>
            </div>
            <div class="text-xs text-base-content/65">
              <p class="mb-1 font-semibold">{label(trace.status)}</p>
              <.handler_report id={id <> "-handler"} report={Map.get(trace, :handler)} />
              <.request_timing id={id <> "-timing"} trace={trace} />
            </div>
          </article>
        </div>
      </div>
      <p
        id="exiron-request-scroll-hint"
        class="border-t border-base-300/70 px-4 py-2 text-[11px] text-base-content/55"
      >
        Newest first. Scroll to browse all retained matches, or focus the list and use the arrow keys.
      </p>
      <div
        :if={@selected}
        id="exiron-request-detail"
        class="border-t border-base-300 bg-base-200/30 p-4"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <h3 class="break-all font-mono text-xs font-bold">{@selected.id}</h3>
            <p class="mt-1 break-words text-xs text-base-content/60">
              Telegram message {@selected.message_id || "unknown"} · route {@selected.route_id ||
                "unknown"} · {label(@selected.status)}
            </p>
            <p class="mt-1 text-xs text-base-content/50">
              Acknowledgement confirms batch handling, not Telegram response delivery.
            </p>
            <p
              :if={@selected.omitted_steps > 0}
              class="mt-1 text-xs text-amber-700 dark:text-amber-300"
            >
              {@selected.omitted_steps} intermediate steps omitted.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <.link
              id="exiron-export-request"
              href={~p"/diagnostics/requests/#{@selected.id}"}
              class="ex-action-button"
            ><.icon name="hero-arrow-down-tray-micro" class="size-4" /> Export diagnostic</.link>
            <button
              id="exiron-close-request"
              type="button"
              phx-click="close_request"
              class="rounded border border-base-300 px-2 py-1 text-xs transition hover:bg-base-200"
            >Close</button>
          </div>
        </div>
        <div class="mt-3 rounded-lg border border-base-300/70 p-3">
          <p class="mb-2 text-xs text-base-content/60">
            Received
            <time id="exiron-detail-received" datetime={DateTime.to_iso8601(@selected.at)}>{Calendar.strftime(
              @selected.at,
              "%Y-%m-%d %H:%M:%S UTC"
            )}</time>
          </p>
          <.handler_report id="exiron-handler-report" report={Map.get(@selected, :handler)} />
          <.request_timing id="exiron-detail-timing" trace={@selected} />
          <ClientConnection.summary
            :if={@selected.client_presence}
            id="exiron-request-client"
            client={@selected.client_presence}
            recipient?={true}
          />
        </div>
        <.cancellation_controls trace={@selected} paused?={@paused?} />
        <ol id="exiron-trace-steps" phx-update="stream" class="mt-3 space-y-2">
          <li
            :for={{id, step} <- @streams.trace_steps}
            id={id}
            data-stage={step.kind}
            class="flex flex-wrap gap-x-3 gap-y-1 border-l-2 border-primary/30 pl-3 text-xs"
          >
            <span class="font-mono text-base-content/50">+{step.elapsed_ms} ms</span>
            <span class="font-semibold">{label(step.kind)}</span>
            <span :if={step.detail} class="text-base-content/60">{step.detail}</span>
          </li>
        </ol>
      </div>
      <div
        :if={@delivery}
        id="exiron-delivery-diagnostics"
        class="min-w-0 border-t border-base-300 bg-base-200/20 p-4"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <h3 class="text-sm font-bold">Delivery details · {@delivery.operation}</h3>
            <p id="exiron-delivery-summary" class="mt-1 break-words text-xs text-base-content/65">
              {label_string(@delivery.outcome)} · {label_string(@delivery.delivery_status)} · {@delivery.attempts} attempts
            </p>
            <p id="exiron-delivery-guidance" class="mt-2 text-sm font-semibold">
              {guidance(@delivery.retry_action)}
            </p>
            <p
              :if={@delivery.last_error}
              id="exiron-delivery-error"
              class="mt-1 text-xs text-base-content/70"
            >
              {@delivery.last_error.message}
              <span :if={@delivery.last_error.code}> · Telegram {@delivery.last_error.code}</span>
              <span :if={@delivery.last_error.retry_after_ms}> · retry delay {@delivery.last_error.retry_after_ms} ms</span>
            </p>
            <p class="mt-2 text-xs text-base-content/60">
              {@delivery.confirmed_parts} confirmed · {@delivery.rejected_parts} rejected · {@delivery.unknown_parts} uncertain · {@delivery.unattempted_parts} not attempted
            </p>
          </div>
          <button
            id="exiron-close-delivery"
            type="button"
            phx-click="close_request"
            class="rounded border border-base-300 px-2 py-1 text-xs transition hover:bg-base-200"
          >Close</button>
        </div>
        <div class="mt-4 min-w-0 overflow-x-auto rounded-lg border border-base-300">
          <table class="w-full text-left text-xs">
            <thead class="bg-base-200 text-base-content/65">
              <tr>
                <th class="p-2">Part / chat</th><th class="p-2">Operation</th><th class="p-2">
                  Outcome
                </th><th class="p-2">Message ID</th><th class="p-2">Attempts / error</th>
              </tr>
            </thead>
            <tbody id="exiron-delivery-parts" phx-update="stream" class="divide-y divide-base-300">
              <tr :for={{id, part} <- @streams.delivery_parts} id={id} data-status={part.status}>
                <td class="p-2 font-mono">{part.index} / {part.chat_id}</td>
                <td class="p-2">
                  {part.operation}<span :if={part.bot_name} class="block text-base-content/50">{part.bot_name}</span>
                </td>
                <td class="p-2">{label_string(part.status)}</td>
                <td class="p-2 font-mono">{part.message_id || "—"}</td>
                <td class="p-2">
                  {part.attempts}<span :if={part.error} class="block text-base-content/60">{part.error.category}<span :if={
                    part.error.code
                  }> ({part.error.code})</span></span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p
          :if={@delivery.omitted_parts > 0}
          id="exiron-delivery-omitted"
          class="mt-2 text-xs text-base-content/60"
        >
          {@delivery.omitted_parts} part details omitted; totals include all parts.
        </p>
        <p class="mt-2 break-all font-mono text-[11px] text-base-content/40">{@delivery.id}</p>
      </div>
    </section>
    """
  end

  def guidance("wait"), do: "Delivery is in progress. Wait before submitting another update."

  def guidance("retry_request"),
    do: "No delivery was confirmed. Wait for the retry delay, then retry explicitly."

  def guidance("fix_request"),
    do: "No delivery was confirmed. Fix the request or bot setup before retrying."

  def guidance("inspect_chat"),
    do:
      "Inspect the chat before retrying or resuming remaining work; duplicate messages are possible."

  def guidance("request_closed"),
    do: "This request is closed. Start new work explicitly if it is still needed."

  def guidance(_), do: "No retry is needed."
  defp label_string(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp label(kind),
    do: kind |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
end
