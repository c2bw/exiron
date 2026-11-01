Code.require_file("support/network_ingress.ex", __DIR__)
Code.require_file("support/network_observer.ex", __DIR__)
Code.require_file("support/network_faults.ex", __DIR__)
Code.require_file("support/binary_owners.ex", __DIR__)

defmodule Exiron.Benchmarks.Network do
  alias Exiron.Hub
  alias Exiron.Hub.{Router, Telegram}

  def run(args) do
    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          duration: :integer,
          rate: :integer,
          hooks: :integer,
          output: :string,
          media_bytes: :integer,
          faults: :boolean,
          quiet: :boolean,
          port: :integer,
          http_idle_ms: :integer
        ]
      )

    if Process.whereis(Hub), do: raise("Run with mix run --no-start")
    duration = opts[:duration] || 60
    rate = opts[:rate] || 100
    hooks = opts[:hooks] || 24
    media_bytes = opts[:media_bytes] || 1_048_576
    port = opts[:port] || 0
    if duration < 1 or rate < 1 or hooks < 1 or media_bytes < 0, do: raise("Invalid workload")
    if port < 0 or port > 65535, do: raise("Invalid port")

    if token = System.get_env("EXIRON_BENCH_METRICS_TOKEN_FILE") do
      Application.put_env(:exiron, :metrics_token, token |> File.read!() |> String.trim())
    end

    Application.put_env(:exiron, :hub,
      enabled: false,
      telegram_pollers_enabled: false,
      send_timeout: 1000
    )

    Application.put_env(
      :exiron,
      ExironWeb.Endpoint,
      Keyword.put(Application.get_env(:exiron, ExironWeb.Endpoint), :server, false)
    )

    {:ok, _} = Application.ensure_all_started(:exiron)
    Logger.configure(level: :warning)
    attempts = :ets.new(:benchmark_attempts, [:public, :set])
    outcomes = :ets.new(:benchmark_outcomes, [:public, :set])
    server_events = :ets.new(:benchmark_server_events, [:public, :set])
    connections = :ets.new(:benchmark_connections, [:public, :set])
    traces = :ets.new(:benchmark_traces, [:public, :set])

    observer =
      Exiron.Benchmarks.NetworkObserver.attach(server_events,
        connections: connections,
        traces: traces
      )

    faults? = Keyword.get(opts, :faults, true)

    sender = fn _, message ->
      cond do
        String.ends_with?(message.data, " is not connected.") ->
          key = {:unavailable, message.chat_id}
          :ets.update_counter(outcomes, key, {2, 1}, {key, 0})

        String.ends_with?(message.data, " is overloaded. Please try again later.") ->
          key = {:overloaded, message.chat_id}
          :ets.update_counter(outcomes, key, {2, 1}, {key, 0})

        true ->
          :ok
      end

      number =
        case Integer.parse(message.data) do
          {number, ""} -> number
          _ -> 1
        end

      receive do
      after
        10 -> :ok
      end

      if Exiron.Benchmarks.NetworkFaults.fail?(attempts, faults?, message.chat_id, number),
        do: {:error, :send_unavailable},
        else: :ok
    end

    telegram =
      Telegram.new(for(i <- 1..hooks, do: %{chat_id: i, bot_token: "fake-bot"}), sender: sender)

    :ok = Hub.configure(router(hooks), telegram)
    control = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    {:ok, server} =
      Bandit.start_link(
        plug:
          {Exiron.Benchmarks.NetworkIngress,
           [control_token: control, media_bytes: media_bytes, outcomes: outcomes]},
        ip: {127, 0, 0, 1},
        port: port
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    binary =
      Path.join(System.tmp_dir!(), "exiron-network-bench-#{System.unique_integer([:positive])}")

    try do
      {output, 0} =
        System.cmd("go", ["build", "-mod=readonly", "-o", binary, "./cmd/exiron-bench"],
          cd: "clients/go",
          stderr_to_stdout: true
        )

      if output != "", do: IO.puts(output)
      tables = %{attempts: attempts, outcomes: outcomes, server_events: server_events}
      progress_path = if opts[:output], do: opts[:output] <> ".progress.jsonl"
      if progress_path, do: File.write!(progress_path, "")

      sampler =
        Task.async(fn ->
          sample(System.monotonic_time(:millisecond), [], tables, progress_path, 0)
        end)

      {output, exit} =
        System.cmd(
          binary,
          [
            "-url",
            "http://127.0.0.1:#{port}",
            "-duration",
            "#{duration}",
            "-rate",
            "#{rate}",
            "-hooks",
            "#{hooks}",
            "-media-bytes",
            "#{media_bytes}",
            "-faults=#{faults?}",
            "-http-idle-ms",
            "#{opts[:http_idle_ms] || 30_000}"
          ],
          env: [{"EXIRON_BENCH_CONTROL", control}]
        )

      send(sampler.pid, :stop)
      samples = Task.await(sampler, 30_000)
      result = Jason.decode!(output)
      state = drained_state(System.monotonic_time(:millisecond) + 5_000)
      observer_attached? = Exiron.Benchmarks.NetworkObserver.attached?(observer)

      report =
        Map.merge(result, %{
          "resources" => samples,
          "pending_at_end" => map_size(state.delivery.pending),
          "sends_at_end" => map_size(state.delivery.sends),
          "queued_at_end" => Enum.sum_by(state.delivery.queues, fn {_, q} -> q.count end),
          "server_events" => Exiron.Benchmarks.NetworkObserver.report(server_events),
          "server_error_traces" => Exiron.Benchmarks.NetworkObserver.traces(traces),
          "server_observer_attached" => observer_attached?,
          "recorded_at" => DateTime.utc_now(),
          "elixir" => System.version(),
          "otp" => System.otp_release(),
          "schedulers" => System.schedulers_online()
        })

      json = Jason.encode!(report, pretty: true)
      if opts[:output], do: File.write!(opts[:output], json <> "\n")

      if exit != 0 or report["pending_at_end"] != 0 or report["sends_at_end"] != 0 or
           not observer_attached?,
         do: raise("Network workload failed delivery or diagnostic integrity checks")

      IO.puts(
        if opts[:quiet],
          do:
            "Network benchmark accounted for #{report["offered"]} offers (#{report["completed"]} completed)",
          else: json
      )
    after
      Supervisor.stop(server)
      File.rm(binary)
      :ets.delete(attempts)
      :ets.delete(outcomes)
      :telemetry.detach(observer)
      :ets.delete(server_events)
      :ets.delete(connections)
      :ets.delete(traces)
    end
  end

  defp drained_state(deadline) do
    state = :sys.get_state(Hub)

    if (map_size(state.delivery.pending) == 0 and map_size(state.delivery.sends) == 0) or
         System.monotonic_time(:millisecond) >= deadline do
      state
    else
      receive do
      after
        20 -> drained_state(deadline)
      end
    end
  end

  defp sample(started, samples, tables, progress_path, next_progress) do
    info = Process.info(Process.whereis(Hub), [:message_queue_len, :memory])
    # Do not copy queues, delivery frames and histories into the sampler's heap.
    state = Hub.metrics_snapshot()
    memory = :erlang.memory()
    word_bytes = :erlang.system_info(:wordsize)

    profile? = System.monotonic_time(:millisecond) - started >= next_progress
    binary_owners = if profile?, do: Exiron.Benchmarks.BinaryOwners.snapshot()

    snapshot = %{
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      mailbox: info[:message_queue_len],
      hub_process_bytes: info[:memory],
      vm_bytes: memory[:total],
      vm_processes_used_bytes: memory[:processes_used],
      vm_binary_bytes: memory[:binary],
      vm_ets_bytes: memory[:ets],
      benchmark_attempts_rows: :ets.info(tables.attempts, :size),
      benchmark_attempts_bytes: :ets.info(tables.attempts, :memory) * word_bytes,
      benchmark_outcomes_bytes: :ets.info(tables.outcomes, :memory) * word_bytes,
      metrics_collector_rows: :ets.info(Exiron.Metrics, :size),
      metrics_collector_bytes: :ets.info(Exiron.Metrics, :memory) * word_bytes,
      pending: state.pending,
      sends: state.sends
    }

    snapshot = if profile?, do: Map.put(snapshot, :binary_owners, binary_owners), else: snapshot

    next_progress =
      if snapshot.elapsed_ms >= next_progress do
        if progress_path,
          do: File.write!(progress_path, Jason.encode!(snapshot) <> "\n", [:append])

        snapshot.elapsed_ms + 60_000
      else
        next_progress
      end

    receive do
      :stop -> Enum.reverse([snapshot | samples])
    after
      1000 -> sample(started, [snapshot | samples], tables, progress_path, next_progress)
    end
  end

  defp router(count) do
    {:ok, router} =
      Router.load_definitions(%{
        "aliases" => %{"telegram" => Map.new(1..count, &{"chat#{&1}", &1})},
        "routes" =>
          Map.new(
            1..count,
            &{"chat#{&1}", %{"middleware" => ["middleware#{&1}"], "push" => true}}
          ),
        "middlewares" =>
          Map.new(
            1..count,
            &{"middleware#{&1}", %{"routes" => %{"hook-#{&1}" => %{"messages" => ["/work"]}}}}
          ),
        "hooks" => Map.new(1..count, &{"hook-#{&1}", "token-#{&1}"})
      })

    router
  end
end

Exiron.Benchmarks.Network.run(System.argv())
