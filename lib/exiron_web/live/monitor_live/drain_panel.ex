defmodule ExironWeb.MonitorLive.DrainPanel do
  @moduledoc false
  use ExironWeb, :html

  attr :drain, :map, required: true
  attr :form, :any, required: true
  attr :paused?, :boolean, required: true
  attr :enabled?, :boolean, required: true

  def panel(assigns) do
    ~H"""
    <section id="exiron-drain" class="ex-panel space-y-4 p-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="flex items-center gap-2 text-sm font-black">
            <.icon name="hero-arrow-down-tray-micro" class="size-4 text-primary" />
            Prepare for restart
          </h2>
          <p class="mt-1 max-w-2xl text-xs text-base-content/60">
            Pause new intake and let accepted work finish. Pending replies and streams continue.
            Readiness stays unhealthy until intake resumes.
          </p>
        </div>
        <span
          id="exiron-drain-phase"
          class="rounded-lg border border-base-300 px-3 py-1 text-xs font-bold"
          data-phase={@drain.phase}
        >
          {phase(@drain.phase)}
        </span>
      </div>
      <.form
        :if={!@drain.active}
        for={@form}
        id="exiron-drain-form"
        phx-submit="start_drain"
        class="flex flex-wrap items-end gap-3"
      >
        <.input
          field={@form[:timeout_seconds]}
          type="number"
          label="Timeout (seconds)"
          min="1"
          max="3600"
          required
        />
        <button
          id="exiron-drain-start"
          type="submit"
          disabled={@paused? or !@enabled?}
          class="rounded-lg bg-primary px-4 py-2 text-xs font-bold text-primary-content transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-40"
          phx-disable-with="Pausing intake…"
        >
          Start drain
        </button>
      </.form>
      <div :if={@drain.active} class="space-y-3">
        <dl class="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <div
            :for={
              {key, label} <- [
                pending_requests: "Pending requests",
                queued_messages: "Queued messages",
                active_sends: "Active sends",
                unacknowledged_batches: "Unacknowledged batches"
              ]
            }
            class="min-w-0 rounded-lg bg-base-200/70 p-3"
          >
            <dt class="text-[11px] text-base-content/60">{label}</dt>
            <dd id={"exiron-drain-#{key}"} class="mt-1 text-xl font-bold tabular-nums">
              {Map.fetch!(@drain, key)}
            </dd>
          </div>
        </dl>
        <p :if={@drain.phase == "timed_out"} id="exiron-drain-timeout" class="text-xs text-warning">
          The timeout elapsed with work outstanding. Intake remains paused; existing work can still finish.
        </p>
        <p :if={@drain.drained} id="exiron-drain-complete" class="text-xs text-success">
          Tracked work has drained. You can restart this instance. In-memory loss and uncertain Telegram delivery still apply.
        </p>
        <button
          id="exiron-drain-resume"
          type="button"
          phx-click="resume_intake"
          disabled={@paused?}
          class="rounded-lg border border-base-300 px-4 py-2 text-xs font-bold transition hover:bg-base-200 disabled:opacity-40"
          phx-disable-with="Resuming…"
        >
          Resume intake
        </button>
      </div>
      <p :if={@paused?} class="text-xs text-base-content/50">
        Resume live updates to use drain controls. Drain progress continues to refresh.
      </p>
    </section>
    """
  end

  defp phase("running"), do: "Accepting work"
  defp phase("draining"), do: "Draining"
  defp phase("drained"), do: "Drained · intake paused"
  defp phase("timed_out"), do: "Timed out · intake paused"
end
