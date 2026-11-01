Code.require_file("../../../benchmarks/support/network_observer.ex", __DIR__)

defmodule Exiron.Benchmarks.NetworkObserverTest do
  use ExUnit.Case, async: true
  alias Exiron.Benchmarks.NetworkObserver

  test "classifies pre-connection read timeouts without retaining private metadata" do
    table = :ets.new(:observer_test, [:set, :public])

    NetworkObserver.handle_event(
      [:bandit, :request, :stop],
      %{duration: System.convert_time_unit(60, :second, :native)},
      %{error: "Read timeout", authorization: "secret-token"},
      table
    )

    assert [
             %{
               event: :stop,
               path: "before_request",
               error: "read_timeout",
               duration: "at_least_60s",
               count: 1
             }
           ] = NetworkObserver.report(table)

    refute inspect(:ets.tab2list(table)) =~ "secret-token"
  end

  test "successes are ignored and unknown paths and errors cannot create unbounded categories" do
    table = :ets.new(:observer_test, [:set, :public])

    NetworkObserver.handle_event(
      [:bandit, :request, :stop],
      %{},
      %{conn: %{request_path: "/metrics"}},
      table
    )

    for id <- 1..100 do
      NetworkObserver.handle_event(
        [:bandit, :request, :exception],
        %{},
        %{exception: "private-#{id}", conn: %{request_path: "/unknown/#{id}"}},
        table
      )
    end

    assert [%{event: :exception, path: "other", error: "other", duration: "unknown", count: 100}] =
             NetworkObserver.report(table)
  end

  test "correlates timeout phase with bounded connection counters without retaining bytes" do
    events = :ets.new(:events, [:set, :public])
    connections = :ets.new(:connections, [:set, :public])
    traces = :ets.new(:traces, [:set, :public])
    config = %{events: events, connections: connections, traces: traces}
    ref = make_ref()

    NetworkObserver.handle_event(
      [:thousand_island, :connection, :start],
      %{},
      %{telemetry_span_context: ref, remote_port: 12345},
      config
    )

    bytes = "private-content-not-for-reporting"

    NetworkObserver.handle_event(
      [:thousand_island, :connection, :recv],
      %{data: bytes},
      %{telemetry_span_context: ref},
      config
    )

    NetworkObserver.handle_event(
      [:thousand_island, :connection, :recv_error],
      %{error: :timeout},
      %{telemetry_span_context: ref},
      config
    )

    NetworkObserver.handle_event(
      [:bandit, :request, :stop],
      %{duration: System.convert_time_unit(60, :second, :native)},
      %{connection_telemetry_span_context: ref, error: "Read timeout"},
      config
    )

    assert [
             %{
               remote_port: 12345,
               received_bytes: count,
               parsed_requests: 0,
               socket_read_timeouts: 1
             }
           ] = NetworkObserver.traces(traces)

    assert count == byte_size(bytes)
    refute inspect(:ets.tab2list(connections)) =~ bytes
    refute inspect(:ets.tab2list(traces)) =~ bytes

    NetworkObserver.handle_event(
      [:thousand_island, :connection, :stop],
      %{},
      %{telemetry_span_context: ref},
      config
    )

    assert :ets.info(connections, :size) == 0
  end
end
