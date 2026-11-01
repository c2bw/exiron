defmodule Exiron.MetricsTest do
  use ExUnit.Case, async: false
  alias Exiron.Metrics

  setup do
    start_supervised!({Metrics, name: __MODULE__, table: __MODULE__})
    :ok
  end

  test "histograms keep cumulative buckets, counts and sums under concurrent writes" do
    durations = [0.005, 0.2, 0.5, 1.2, 90]

    Task.async_stream(
      1..50,
      fn _ ->
        for duration <- durations do
          native = System.convert_time_unit(round(duration * 1_000_000), :microsecond, :native)

          Metrics.handle_event(
            [:exiron, :hub, :response, :stop],
            %{duration: native},
            %{hook: "ignored"},
            __MODULE__
          )
        end
      end,
      timeout: :infinity
    )
    |> Stream.run()

    text = Metrics.render(nil, __MODULE__)
    assert text =~ "exiron_response_duration_seconds_bucket{le=\"0.01\"} 50\n"
    assert text =~ "exiron_response_duration_seconds_bucket{le=\"0.5\"} 150\n"
    assert text =~ "exiron_response_duration_seconds_bucket{le=\"+Inf\"} 250\n"
    assert text =~ "exiron_response_duration_seconds_count 250\n"
    assert text =~ "exiron_response_duration_seconds_sum 4595.25\n"
    assert text =~ "exiron_hub_snapshot_available 0\n"
    refute text =~ "ignored"
    assert String.ends_with?(text, "\n")
  end

  test "collector series remain fixed when hook names change and unexpected tags are ignored" do
    for id <- 1..1000 do
      Metrics.handle_event(
        [:exiron, :hub, :response, :stop],
        %{duration: 1},
        %{hook: "hook-#{id}"},
        __MODULE__
      )

      Metrics.handle_event(
        [:exiron, :hub, :send, :stop],
        %{duration: 1},
        %{kind: "arbitrary", outcome: :ok},
        __MODULE__
      )
    end

    assert :ets.info(__MODULE__, :size) == 17
    text = Metrics.render(nil, __MODULE__)
    refute text =~ "arbitrary"
    refute text =~ "hook-1000"
  end

  test "a restarted collector attaches once and starts fresh histograms" do
    stop_supervised!(Metrics)
    start_supervised!({Metrics, name: __MODULE__, table: __MODULE__})
    Exiron.Telemetry.response(System.convert_time_unit(100, :millisecond, :native), "assistant")

    assert [{:response, 1, 100_000, _a, _b, _c, _d, _e, _f, _g, _h, _i, _j, _k, _l, _m, _n, _o}] =
             :ets.lookup(__MODULE__, :response)
  end

  test "scrape escapes hook labels and exports limits without credentials" do
    hook = %{
      name: "line\n\"\\",
      connected: false,
      buffered_bytes: 5,
      buffered_bytes_limit: 100,
      health: %{
        queued: 1,
        queued_bytes: 3,
        pending: 1,
        unavailable_rejections: 2,
        overload_rejections: 0,
        in_flight_sends: 2,
        in_flight_send_limit: 10,
        send_capacity_rejections: 3,
        in_flight_send_bytes: 12,
        in_flight_send_bytes_limit: 100,
        send_byte_capacity_rejections: 2,
        send_failures: 1
      },
      bot_token: "secret"
    }

    text =
      Metrics.render(
        %{
          enabled: true,
          hooks: [hook],
          pending: 1,
          pending_limit: 1000,
          buffer_capacity: %{
            bytes: 5,
            limit: 100,
            awaiting_ack_bytes: 2,
            request_rejections: 3,
            listener_rejections: 4
          },
          sends: 0,
          sends_limit: 100,
          send_capacity: %{bytes: 12, limit: 200, rejections: 2},
          telegram_suppression: %{
            available: true,
            active: 1,
            suppressed_attempts: 2,
            probes: 3,
            recoveries: 4
          }
        },
        __MODULE__
      )

    assert text =~ ~S(exiron_hook_queued_bytes{hook="line\n\"\\"} 3)
    assert text =~ "exiron_pending_limit 1000\n"
    assert text =~ "exiron_in_flight_sends_limit 100\n"
    assert text =~ ~S(exiron_hook_in_flight_sends{hook="line\n\"\\"} 2)
    assert text =~ ~S(exiron_hook_in_flight_sends_limit{hook="line\n\"\\"} 10)
    assert text =~ ~S(exiron_hook_send_capacity_rejections_total{hook="line\n\"\\"} 3)
    assert text =~ "exiron_buffered_bytes 5\n"
    assert text =~ "exiron_buffered_bytes_limit 100\n"
    assert text =~ "exiron_buffered_awaiting_ack_bytes 2\n"
    assert text =~ "exiron_buffer_request_rejections_total 3\n"
    assert text =~ "exiron_buffer_listener_rejections_total 4\n"
    assert text =~ "exiron_in_flight_send_bytes 12\n"
    assert text =~ "exiron_in_flight_send_bytes_limit 200\n"
    assert text =~ "exiron_send_byte_capacity_rejections_total 2\n"
    assert text =~ ~S(exiron_hook_in_flight_send_bytes{hook="line\n\"\\"} 12)
    assert text =~ "exiron_telegram_suppressions 1\n"
    assert text =~ "exiron_telegram_suppressed_attempts_total 2\n"
    assert text =~ "exiron_telegram_recoveries_total 4\n"
    refute text =~ "secret"
  end
end
