defmodule ExironWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Hub metrics. Domain modules emit these through Exiron.Telemetry so the
      # metadata is deliberately limited to bounded operational dimensions.
      last_value("exiron.hub.queue.count", tags: [:hook]),
      last_value("exiron.hub.queue.bytes", tags: [:hook], unit: :byte),
      sum("exiron.hub.queue.dropped", tags: [:hook]),
      last_value("exiron.hub.pending.count"),
      last_value("exiron.hub.sends.count"),
      sum("exiron.hub.delivery.rejected.count", tags: [:hook, :reason]),
      summary("exiron.hub.response.stop.duration",
        tags: [:hook],
        unit: {:native, :millisecond}
      ),
      summary("exiron.hub.send.stop.duration",
        tags: [:kind, :outcome],
        unit: {:native, :millisecond}
      ),
      counter("exiron.hub.send.stop.count", tags: [:kind, :outcome]),
      summary("exiron.hub.status.snapshot.stop.duration",
        tags: [:scope],
        unit: {:native, :millisecond}
      ),
      summary("exiron.hub.status.snapshot.stop.bytes", tags: [:scope], unit: :byte),
      summary("exiron.hub.reload.stop.duration",
        tags: [:action, :outcome],
        unit: {:native, :millisecond}
      ),
      counter("exiron.hub.reload.stop.count", tags: [:action, :outcome]),
      summary("exiron.hub.lookup.stop.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),
      summary("exiron.telegram.poll.stop.duration",
        tags: [:outcome],
        unit: {:native, :millisecond}
      ),
      sum("exiron.hub.delivery.redelivery.count", tags: [:transport]),
      sum("exiron.hub.listener.drop.count", tags: [:hook, :reason]),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {ExironWeb, :count_users, []}
    ]
  end
end
