Code.require_file("../../../benchmarks/support/network_observer.ex", __DIR__)

defmodule Exiron.Benchmarks.NetworkTimeoutTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Exiron.Benchmarks.NetworkObserver

  test "an idle TCP connection can time out before any HTTP request is constructed" do
    events = :ets.new(:events, [:set, :public])
    connections = :ets.new(:connections, [:set, :public])
    traces = :ets.new(:traces, [:set, :public])
    observer = NetworkObserver.attach(events, connections: connections, traces: traces)
    on_exit(fn -> :telemetry.detach(observer) end)

    server =
      start_supervised!(
        {Bandit,
         plug: fn conn, _ -> Plug.Conn.send_resp(conn, 200, "ok") end,
         ip: {127, 0, 0, 1},
         port: 0,
         thousand_island_options: [read_timeout: 50],
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    capture_log(fn ->
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)

      try do
        {:ok, {_, local_port}} = :inet.sockname(socket)
        # Send no request bytes. Initial protocol sniffing times out, then the
        # HTTP header read times out too. This reproduces the early error phase.
        assert {:ok, response} = :gen_tcp.recv(socket, 0, 2000)
        assert response =~ "408"
        trace = Enum.find(NetworkObserver.traces(traces), &(&1.remote_port == local_port))

        assert %{
                 error: "read_timeout",
                 path: "before_request",
                 received_bytes: 0,
                 parsed_requests: 0,
                 socket_read_timeouts: timeouts
               } = trace

        assert timeouts >= 2
      after
        :gen_tcp.close(socket)
      end
    end)
  end
end
