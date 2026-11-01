defmodule ExironClient.LifecycleScenariosTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias ExironClient.{
    HandlerDeadline,
    LifecycleGateway,
    LifecycleSocketServer,
    Poller,
    Quarantine
  }

  @catalog_path Path.expand("../../contract/lifecycle/managed.json", __DIR__)
  @external_resource @catalog_path
  @catalog @catalog_path |> File.read!() |> Jason.decode!()

  for scenario <- @catalog["cases"] do
    @scenario scenario
    test "shared managed lifecycle: #{scenario["id"]}" do
      scenario = @scenario
      assert @catalog["scenario_version"] == "1"
      parent = self()

      gateway =
        start_supervised!(
          {LifecycleGateway, %{scenario: scenario, catalog: @catalog, parent: parent}}
        )

      port =
        if scenario["transport"] == "websocket",
          do: LifecycleSocketServer.start!(gateway),
          else: 4000

      client =
        ExironClient.new(
          base_url: "http://127.0.0.1:#{port}",
          token: "synthetic",
          client_id: "lifecycle",
          reconnect_backoff: [
            initial_delay_ms: 1,
            max_delay_ms: 5,
            max_retry_time_ms: 1000,
            jitter: false
          ],
          req_options: [adapter: LifecycleGateway.adapter(gateway)]
        )

      store = start_supervised!({Quarantine, max_messages: 10, max_bytes: 65536})
      handler = handler(scenario, client, gateway, parent)

      opts = [
        runtime_reporting: false,
        client: client,
        handler: handler,
        transport: transport(scenario),
        graceful_shutdown: true,
        interval_ms: 10,
        disconnect_timeout_ms: 1000,
        handler_timeout_ms: scenario["handler_timeout_ms"],
        quarantine: store
      ]

      opts =
        if scenario["operation"] in ["quarantine_recovery_restart", "deadline_during_stream"],
          do: Keyword.put(opts, :handler_failure_policy, :quarantine),
          else: opts

      opts =
        if scenario["operation"] == "cancellation_during_stream",
          do:
            opts ++
              [
                cooperative_cancellation: true,
                cancellation_interval_ms: scenario["cancellation_interval_ms"]
              ],
          else: opts

      {pid, monitor} = start_client(opts)
      initial = %{pid: pid, monitor: monitor, worker: nil, drain_ref: nil, outcome: nil}

      final =
        Enum.reduce(scenario["steps"], initial, fn step, state ->
          step(step, state, opts, gateway, store, client)
        end)

      outcome =
        if scenario["operation"] == "quarantine_recovery_restart",
          do: "recovered_and_restarted",
          else: final.outcome

      assert {:ok, %{count: count}} = Quarantine.stats(store)
      LifecycleGateway.observe(gateway, "quarantined_final", count)

      if scenario["operation"] == "quarantine_recovery_restart",
        do: LifecycleGateway.observe(gateway, "quarantined_after_restart", count)

      LifecycleGateway.observe(gateway, "outcome", outcome)
      assert LifecycleGateway.observed(gateway) == scenario["expect"]
      assert {:error, :not_running} = Poller.status(final.pid)
    end
  end

  defp transport(%{"transport" => "http"}), do: :http
  defp transport(%{"transport" => "websocket"}), do: :websocket

  defp start_client(opts) do
    pid =
      start_supervised!(%{
        id: make_ref(),
        start: {Poller, :start_link, [opts]},
        restart: :temporary
      })

    {pid, Process.monitor(pid)}
  end

  defp handler(scenario, client, gateway, parent) do
    fn message ->
      LifecycleGateway.add(gateway, "handler_calls")
      send(parent, {:lifecycle_handler, self()})

      case scenario["operation"] do
        operation when operation in ["failure_during_drain", "quarantine_recovery_restart"] ->
          receive do
            :fail ->
              {:error, :synthetic_handler_failure}

            :complete ->
              normalize(ExironClient.reply_text(client, message, @catalog["reply_text"]))
          end

        operation when operation in ["deadline_during_stream", "cancellation_during_stream"] ->
          chunks =
            Stream.map([@catalog["partial_text"], "late"], fn part ->
              if part == "late" do
                if operation == "deadline_during_stream" do
                  HandlerDeadline.wait(10000)
                else
                  receive do
                    {:exiron_request_cancelled, _, :cancelled} -> :ok
                  end
                end
              end

              part
            end)

          normalize(ExironClient.stream_text(client, message, chunks, interval_ms: 1))

        "connection_loss_before_ack" ->
          normalize(ExironClient.reply_text(client, message, @catalog["reply_text"]))
      end
    end
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, _} = error), do: error

  defp step("await_handler", state, _, _, _, _) do
    assert_receive {:lifecycle_handler, worker}, 3000
    %{state | worker: worker}
  end

  defp step("await_partial", state, _, _, _, _) do
    assert_receive :lifecycle_partial, 3000
    state
  end

  defp step("start_drain", state, _, _, _, _) do
    ref = make_ref()
    send(state.pid, {:client_drain, self(), ref, ExironClient.ClientDrain.now() + 3000})
    _ = :sys.get_state(state.pid)
    assert {:ok, %{phase: :draining}} = Poller.status(state.pid)
    %{state | drain_ref: ref}
  end

  defp step("fail_handler", state, _, _, _, _),
    do:
      (
        send(state.worker, :fail)
        state
      )

  defp step("complete_handler", state, _, _, _, _),
    do:
      (
        send(state.worker, :complete)
        state
      )

  defp step("cancel_request", state, _, gateway, _, _),
    do:
      (
        LifecycleGateway.cancel(gateway)
        state
      )

  defp step("await_failed_stop", state, _, _, _, _) do
    %{pid: pid, monitor: monitor, drain_ref: ref} = state
    assert_receive {:client_drain_result, ^ref, {:error, :synthetic_handler_failure}}, 3000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 3000
    %{state | outcome: "handler_failed"}
  end

  defp step("await_deadline_stop", state, _, _, store, _) do
    %{pid: pid, monitor: monitor} = state

    assert_receive {:DOWN, ^monitor, :process, ^pid,
                    %ExironClient.Error{reason: :handler_deadline_exceeded}},
                   3000

    assert {:ok, %{count: 0}} = Quarantine.stats(store)
    %{state | outcome: "deadline_exceeded"}
  end

  defp step("await_drained_stop", state, _, _, _, _) do
    %{pid: pid, monitor: monitor, drain_ref: ref} = state
    assert_receive {:client_drain_result, ^ref, :ok}, 3000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 3000
    %{state | outcome: "drained"}
  end

  defp step("await_acknowledgement", state, _, _, _, _) do
    assert_receive :lifecycle_acknowledged, 3000
    state
  end

  defp step("drain", state, _, _, _, _) do
    assert :ok = Poller.drain(state.pid, 3000)
    %{pid: pid, monitor: monitor} = state
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 3000
    %{state | outcome: "drained"}
  end

  defp step("check_quarantine", state, _, gateway, store, _) do
    {:ok, %{count: count}} = Quarantine.stats(store)
    LifecycleGateway.observe(gateway, "quarantined_before_recovery", count)
    state
  end

  defp step("recover", state, _, gateway, store, client) do
    assert {:ok, [entry]} = Quarantine.entries(store)

    assert :ok =
             Quarantine.recover(store, entry.id, fn message ->
               normalize(ExironClient.reply_text(client, message, @catalog["recovery_text"]))
             end)

    {:ok, %{count: count}} = Quarantine.stats(store)
    LifecycleGateway.observe(gateway, "quarantined_after_recovery", count)
    state
  end

  defp step("restart", state, opts, _, _, _) do
    {pid, monitor} = start_client(opts)
    %{state | pid: pid, monitor: monitor, worker: nil, drain_ref: nil}
  end
end
