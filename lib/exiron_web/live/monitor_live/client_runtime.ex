defmodule ExironWeb.MonitorLive.ClientRuntime do
  @moduledoc false
  use ExironWeb, :html
  attr :id, :string, required: true
  attr :report, :any, default: nil

  def summary(assigns) do
    ~H"""
    <section
      id={@id}
      aria-label="Client-reported runtime"
      class="mt-3 min-w-0 rounded-xl border border-base-content/10 bg-base-200/35 p-3"
    >
      <div class="flex min-w-0 flex-wrap items-center justify-between gap-2">
        <p class="flex items-center gap-1.5 text-[11px] font-semibold text-base-content/75">
          <.icon name="hero-signal" class="size-3.5" /> Client-reported runtime
        </p>
        <span
          :if={@report}
          id={@id <> "-freshness"}
          data-status={@report.status}
          class={[
            "rounded-full px-2 py-0.5 text-[10px] font-semibold",
            if(@report.stale,
              do: "bg-amber-500/10 text-amber-700 dark:text-amber-300",
              else: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
            )
          ]}
        >
          {freshness(@report.status)}
        </span>
      </div>
      <%= if @report do %>
        <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px]">
          <span id={@id <> "-phase"} class="font-semibold capitalize">{String.replace(
            @report.phase,
            "_",
            " "
          )}</span>
          <span id={@id <> "-reported"} class="text-base-content/50">
            Received
            <time
              datetime={DateTime.to_iso8601(@report.reported_at)}
              title={Calendar.strftime(@report.reported_at, "%Y-%m-%d %H:%M:%S UTC")}
            >{age(@report.age_ms)}</time>
            ago
          </span>
        </div>
        <div class="mt-3 grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-3">
          <div class="min-w-0 rounded-lg bg-base-100/70 px-2.5 py-2">
            <p class="text-[10px] text-base-content/50">Active handlers</p>
            <p id={@id <> "-active"} class="text-sm font-semibold tabular-nums">
              {@report.active_handlers}
            </p>
          </div>
          <div class={[
            "min-w-0 rounded-lg px-2.5 py-2",
            if(@report.overdue_handlers > 0,
              do: "bg-amber-500/10 text-amber-700 dark:text-amber-300",
              else: "bg-base-100/70"
            )
          ]}>
            <p class="text-[10px] opacity-60">Overdue handlers</p>
            <p id={@id <> "-overdue"} class="text-sm font-semibold tabular-nums">
              {@report.overdue_handlers}
            </p>
          </div>
          <div class="min-w-0 rounded-lg bg-base-100/70 px-2.5 py-2">
            <p class="text-[10px] text-base-content/50">Quarantined</p>
            <p id={@id <> "-quarantine"} class="break-words text-sm font-semibold tabular-nums">
              <%= cond do %>
                <% not @report.quarantine_enabled -> %>
                  Not configured
                <% not @report.quarantine_available -> %>
                  Unavailable
                <% true -> %>
                  {@report.quarantined_messages}
                  <span class="text-[10px] font-normal text-base-content/50">· {bytes(
                    @report.quarantine_bytes
                  )}</span>
              <% end %>
            </p>
          </div>
        </div>
        <p class="mt-2 text-[10px] leading-relaxed text-base-content/45">
          <%= if @report.stale do %>
            Last observation only. Current work may differ.
          <% else %>
            Observation only; connection and delivery state are tracked separately.
          <% end %>
        </p>
      <% else %>
        <p id={@id <> "-missing"} class="mt-2 text-[11px] leading-relaxed text-base-content/45">
          No runtime telemetry received. Reporting may be disabled or unavailable. SDK version reporting is separate.
        </p>
      <% end %>
    </section>
    """
  end

  defp freshness("fresh"), do: "Fresh"
  defp freshness("stale"), do: "Stale"
  defp freshness("session_inactive"), do: "Stale · session ended"
  defp age(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp age(ms), do: "#{div(ms, 60_000)}m"
  defp bytes(n) when n < 1024, do: "#{n} B"
  defp bytes(n) when n < 1_048_576, do: "#{Float.round(n / 1024, 1)} KiB"
  defp bytes(n), do: "#{Float.round(n / 1_048_576, 1)} MiB"
end
