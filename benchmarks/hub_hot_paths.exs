defmodule Exiron.Benchmarks.HubHotPaths do
  alias Exiron.Hub.{Message, QueueBuffer, Router}

  @default_samples 500
  @default_batch_size 100

  def run(args) do
    {samples, batch_size} =
      if "--smoke" in args, do: {3, 2}, else: {@default_samples, @default_batch_size}

    router = router_fixture()
    message = Message.new(222, 123, "text", "/command99 payload")
    queue = QueueBuffer.from_items(List.duplicate(message, 100))

    benchmarks = [
      {"indexed route match", fn -> Router.match(router, message) end},
      {"bounded queue push", fn -> QueueBuffer.push(queue, message, {100, 1_000_000}) end},
      {"client payload encode",
       fn -> message |> Message.to_client("request-1") |> Jason.encode!() end}
    ]

    unless "--smoke" in args do
      IO.puts("Exiron hub hot-path benchmark (#{samples} samples)")
    end

    Enum.each(benchmarks, fn {name, operation} ->
      calibrated_batch_size = calibrate(operation, batch_size)
      warm_up(operation, calibrated_batch_size)
      durations = sample(operation, samples, calibrated_batch_size)

      unless "--smoke" in args do
        report(name, durations, calibrated_batch_size)
      end
    end)
  end

  defp calibrate(operation, batch_size) do
    target = System.convert_time_unit(1, :millisecond, :native)
    elapsed = elapsed(operation, batch_size)

    if elapsed >= target or batch_size >= 1_000_000 do
      batch_size
    else
      multiplier = max(ceil(target / max(elapsed, 1)), 2)
      calibrate(operation, min(batch_size * multiplier, 1_000_000))
    end
  end

  defp warm_up(operation, batch_size), do: repeat(operation, batch_size * 10)

  defp sample(operation, samples, batch_size) do
    for _sample <- 1..samples do
      elapsed(operation, batch_size)
    end
  end

  defp elapsed(operation, batch_size) do
    started_at = System.monotonic_time()
    repeat(operation, batch_size)
    System.monotonic_time() - started_at
  end

  defp repeat(operation, count) do
    Enum.each(1..count, fn _iteration -> operation.() end)
  end

  defp report(name, durations, batch_size) do
    ordered = Enum.sort(durations)
    median = max(percentile(ordered, 0.50), 1) / batch_size
    p95 = max(percentile(ordered, 0.95), 1) / batch_size
    median_us = System.convert_time_unit(round(median), :native, :microsecond)
    p95_us = System.convert_time_unit(round(p95), :native, :microsecond)
    ips = System.convert_time_unit(1, :second, :native) / median

    statistics = [
      ips |> round() |> Integer.to_string() |> String.pad_leading(10),
      " ops/s  median ",
      median_us |> Integer.to_string() |> String.pad_leading(6),
      " us  p95 ",
      p95_us |> Integer.to_string() |> String.pad_leading(6),
      " us"
    ]

    IO.puts([String.pad_trailing(name, 24), " ", statistics])
  end

  defp percentile(ordered, percentile) do
    index = ordered |> length() |> Kernel.*(percentile) |> Float.ceil() |> trunc() |> max(1)
    Enum.at(ordered, index - 1)
  end

  defp router_fixture do
    routes =
      for index <- 1..100 do
        %{
          id: "route-#{index}",
          service_id: 222,
          chat_id: 123,
          chat_alias: "benchmark",
          to: "hook-#{index}",
          messages: ["/command#{index}"],
          push: true,
          default_bot: nil
        }
      end

    %Router{
      routes: routes,
      routes_by_address: %{{222, 123} => routes},
      routes_by_hook: Enum.group_by(routes, & &1.to),
      hooks: Map.new(routes, &{&1.to, "token-#{&1.id}"})
    }
  end
end

Exiron.Benchmarks.HubHotPaths.run(System.argv())
