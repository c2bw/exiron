Mix.ensure_application!(:tools)

defmodule Exiron.Benchmarks.HubConcurrent do
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Router, Telegram}

  def run(args) do
    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          smoke: :boolean,
          output: :string,
          hooks: :integer,
          rounds: :integer,
          media_bytes: :integer,
          observer: :boolean,
          profile: :string
        ]
      )

    if Process.whereis(Hub), do: raise("Run with mix run --no-start in a fresh VM")

    Application.put_env(:exiron, :hub, enabled: false, telegram_pollers_enabled: false)

    Application.put_env(
      :exiron,
      ExironWeb.Endpoint,
      Keyword.put(Application.get_env(:exiron, ExironWeb.Endpoint), :server, false)
    )

    {:ok, _} = Application.ensure_all_started(:exiron)
    smoke? = opts[:smoke] || false
    rounds = opts[:rounds] || if(smoke?, do: 2, else: 30)
    scales = if opts[:hooks], do: [opts[:hooks]], else: if(smoke?, do: [2], else: [1, 8, 24])

    sizes =
      if opts[:media_bytes],
        do: [opts[:media_bytes]],
        else: [0, if(smoke?, do: 4096, else: 1_048_576)]

    if rounds < 1 or Enum.any?(scales, &(&1 < 1)) or Enum.any?(sizes, &(&1 < 0)),
      do: raise("Workload sizes must be positive (media bytes may be zero)")

    if opts[:profile] && length(scales) * length(sizes) != 1,
      do: raise("Profiling requires --hooks and --media-bytes for one scenario")

    unless smoke?, do: scenario(2, 3, 4096)

    results =
      for hooks <- scales, media_bytes <- sizes do
        scenario(hooks, rounds, media_bytes, opts)
      end

    report = %{
      recorded_at: DateTime.utc_now(),
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online(),
      scope:
        "Hub boundary; simulated Telegram sends; no HTTP/WebSocket network or LiveView rendering",
      load_model: "closed loop: one concurrent client per hook, batches of four requests",
      scenarios: results
    }

    json = Jason.encode!(report, pretty: true)
    if opts[:output], do: File.write!(opts[:output], json <> "\n")
    IO.puts(if smoke?, do: "Concurrent Hub benchmark smoke checks passed", else: json)
  end

  defp scenario(hooks, rounds, media_bytes, opts \\ []) do
    router = router(hooks)

    telegram =
      Telegram.new(for(i <- 1..hooks, do: %{chat_id: i, bot_token: "fake-bot"}),
        sender: fn _, _ ->
          # Controlled network latency, never a real Telegram request.
          receive do
          after
            10 -> :ok
          end
        end
      )

    :ok = Hub.configure(router, telegram)
    hub = Process.whereis(Hub)

    sampler =
      Task.async(fn ->
        sample(hub, %{mailbox_peak: 0, hub_heap_peak: 0, vm_peak: 0, samples: 0})
      end)

    observer = if Keyword.get(opts, :observer, true), do: Task.async(fn -> observe() end)

    if opts[:profile] do
      {:ok, _} = :eprof.start()
      :ok = :eprof.log(String.to_charlist(opts[:profile]))
      :profiling = :eprof.start_profiling([hub], {:_, :_, :_}, set_on_spawn: false)
    end

    payload = :binary.copy(<<42>>, media_bytes)
    started = System.monotonic_time(:microsecond)

    results =
      1..hooks
      |> Task.async_stream(&client(&1, rounds, payload),
        max_concurrency: hooks,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    elapsed = System.monotonic_time(:microsecond) - started
    send(sampler.pid, :stop)

    if opts[:profile] do
      :profiling_stopped = :eprof.stop_profiling()
      :ok = :eprof.analyze(:total, sort: :time)
      :stopped = :eprof.stop()
    end

    if observer, do: send(observer.pid, :stop)
    resources = Task.await(sampler, 30_000)
    observations = if observer, do: Task.await(observer, 30_000), else: nil
    state = :sys.get_state(Hub)
    if map_size(state.delivery.pending) != 0, do: raise("Pending work leaked")
    if map_size(state.delivery.sends) != 0, do: raise("Send work leaked")
    if state.activity.overload_events != [], do: raise("Unexpected overload")

    if Enum.any?(state.delivery.queues, fn {_, queue} -> queue.count != 0 end),
      do: raise("Queued work leaked")

    durations = Enum.flat_map(results, & &1.cycles)
    ingress = Enum.flat_map(results, & &1.ingress)
    sends = Enum.flat_map(results, & &1.sends)

    Map.merge(resources, %{
      profiled: opts[:profile] != nil,
      monitoring: observer != nil,
      hooks: hooks,
      rounds_per_hook: rounds,
      media_bytes: byte_size(payload),
      send_delay_ms: 10,
      completed_requests: hooks * rounds * 4,
      elapsed_ms: elapsed / 1000,
      requests_per_second: Float.round(hooks * rounds * 4 * 1_000_000 / elapsed, 2),
      batch_completion_ms: percentiles(durations),
      ingress_call_ms: percentiles(ingress),
      response_call_ms: percentiles(sends),
      observer: observations,
      pending_at_end: map_size(state.delivery.pending)
    })
  end

  defp client(index, rounds, payload) do
    token = "token-#{index}"
    hook = "hook-#{index}"
    socket? = rem(index, 2) == 0
    opts = [client_id: hook, listen: true]

    if socket? do
      {:ok, %{messages: []}} = Hub.connect_socket(token, opts ++ [pid: self()])
    else
      {:ok, %{requests: []}} = Hub.poll_delivery(token, opts)
    end

    result =
      Enum.reduce(1..rounds, %{cycles: [], ingress: [], sends: []}, fn round, acc ->
        started = System.monotonic_time(:microsecond)

        ingress =
          for number <- 1..4 do
            {duration, :ok} =
              timed(fn ->
                Hub.incoming_service_message(
                  Message.new(222, index, "text", "/work #{round}:#{number}", "fake-bot")
                )
              end)

            duration
          end

        media? = byte_size(payload) > 0 and rem(round, 2) == 0

        if media?,
          do: Hub.incoming_service_message(Message.new(222, index, "file", payload, "fake-bot"))

        expected = if media?, do: 5, else: 4
        items = receive_items(socket?, token, hook, opts, expected, rem(round, 2) == 0)
        # Include actual wire serialization costs at the client boundary.
        _encoded = Jason.encode!(items)
        listeners = Enum.filter(items, &(&1.msgtype == "listen"))

        if media? do
          [%{datatype: "file", data: encoded}] = listeners
          if Base.decode64!(encoded) != payload, do: raise("Media payload mismatch")
        else
          if listeners != [], do: raise("Unexpected listener payload")
        end

        requests = Enum.filter(items, &(&1.msgtype == "request"))
        if length(requests) != 4, do: raise("Missing routed requests")
        if length(Enum.uniq_by(requests, & &1.req_id)) != 4, do: raise("Duplicate request IDs")

        sends =
          Enum.map(requests, fn request ->
            {duration, :ok} = timed(fn -> Hub.respond(token, request.req_id, "text", "done") end)
            duration
          end)

        if media? do
          {:ok, _} = Hub.push(token, "file", payload, index)
        end

        %{
          cycles: [System.monotonic_time(:microsecond) - started | acc.cycles],
          ingress: ingress ++ acc.ingress,
          sends: sends ++ acc.sends
        }
      end)

    if socket?, do: Hub.disconnect_socket(hook, hook, self())
    result
  end

  defp receive_items(false, token, _hook, opts, expected, replay?) do
    {:ok, %{delivery_id: id, requests: items}} = Hub.poll_delivery(token, opts)

    if replay? do
      {:ok, %{delivery_id: ^id, requests: ^items}} = Hub.poll_delivery(token, opts)
    end

    if length(items) != expected, do: raise("Unexpected HTTP delivery count")
    {:ok, %{requests: []}} = Hub.poll_delivery(token, opts ++ [delivery_ack: id])
    items
  end

  defp receive_items(true, token, hook, opts, expected, replay?) do
    receive do
      {:exiron_messages, ref, items} ->
        Hub.complete_socket_delivery(hook, hook, self(), ref)
        remaining = expected - length(items)

        cond do
          remaining == 0 -> items
          remaining > 0 -> items ++ receive_items(true, token, hook, opts, remaining, replay?)
          true -> raise "Unexpected socket delivery count"
        end
    after
      30_000 -> raise "Socket delivery timed out"
    end
  end

  defp sample(hub, peaks) do
    info = Process.info(hub, [:message_queue_len, :memory])

    peaks = %{
      mailbox_peak: max(peaks.mailbox_peak, info[:message_queue_len]),
      hub_heap_peak: max(peaks.hub_heap_peak, info[:memory]),
      vm_peak: max(peaks.vm_peak, :erlang.memory(:total)),
      samples: peaks.samples + 1
    }

    receive do
      :stop -> peaks
    after
      10 -> sample(hub, peaks)
    end
  end

  defp observe do
    :ok = Hub.subscribe_status()
    observe(System.monotonic_time(:millisecond), [], 0)
  end

  defp observe(next_snapshot, durations, updates) do
    now = System.monotonic_time(:millisecond)

    {next_snapshot, durations} =
      if now >= next_snapshot do
        {duration, _} = timed(fn -> Hub.status() |> Jason.encode!() end)
        {now + 100, [duration | durations]}
      else
        {next_snapshot, durations}
      end

    receive do
      :stop ->
        %{updates: updates, status_read_ms: percentiles(durations)}

      {kind, data} when kind in [:hub_status, :hub_status_delta] ->
        _encoded = Jason.encode!(data)
        observe(next_snapshot, durations, updates + 1)
    after
      10 -> observe(next_snapshot, durations, updates)
    end
  end

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - started, result}
  end

  defp percentiles(values) do
    sorted = Enum.sort(values)

    Map.new([{:p50, 0.5}, {:p95, 0.95}, {:p99, 0.99}], fn {label, p} ->
      {label, Enum.at(sorted, max(ceil(length(sorted) * p) - 1, 0), 0) / 1000}
    end)
  end

  defp router(count) do
    definitions = %{
      "aliases" => %{"telegram" => Map.new(1..count, &{"chat#{&1}", &1})},
      "routes" =>
        Map.new(1..count, &{"chat#{&1}", %{"middleware" => ["middleware#{&1}"], "push" => true}}),
      "middlewares" =>
        Map.new(
          1..count,
          &{"middleware#{&1}", %{"routes" => %{"hook-#{&1}" => %{"messages" => ["/work"]}}}}
        ),
      "hooks" => Map.new(1..count, &{"hook-#{&1}", "token-#{&1}"})
    }

    {:ok, router} = Router.load_definitions(definitions)
    router
  end
end

Exiron.Benchmarks.HubConcurrent.run(System.argv())
