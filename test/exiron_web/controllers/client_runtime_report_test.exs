defmodule ExironWeb.ClientRuntimeReportTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub

  setup do
    :ok = Hub.configure(Exiron.HubCase.load_router!(), Exiron.Hub.Telegram.new([]))
    {:ok, delivery} = Hub.poll_delivery("ai-token", client_id: "worker")
    %{payload: payload(delivery.runtime_ref)}
  end

  test "authenticated reports retain only gauges without renewing contact, lease, or delivery", %{
    conn: conn,
    payload: payload
  } do
    before = :sys.get_state(Hub)
    assert conn |> post("/api/client-runtime", payload) |> json_response(401)

    assert conn |> auth() |> post("/api/client-runtime", payload) |> json_response(200) == %{
             "ok" => true
           }

    after_state = :sys.get_state(Hub)
    assert before.delivery.clients == after_state.delivery.clients
    assert before.delivery.pending == after_state.delivery.pending
    assert before.delivery.queues == after_state.delivery.queues

    assert before.delivery.client_presence["assistant"].last_contact_at ==
             after_state.delivery.client_presence["assistant"].last_contact_at

    assert before.delivery.client_presence["assistant"].last_contact_kind ==
             after_state.delivery.client_presence["assistant"].last_contact_kind

    {:ok, status} = Hub.status_for_token("ai-token")
    report = hd(status.hooks).client.runtime
    assert report.active_handlers == 2
    assert report.overdue_handlers == 1
    assert report.status == "fresh"
    refute report.stale
    refute Map.has_key?(report, :runtime_ref)
    refute Map.has_key?(report, :sequence)
    refute Map.has_key?(report, :client_id)
  end

  test "unknown fields, invalid phases and out-of-bounds gauges are rejected without mutation", %{
    conn: conn,
    payload: payload
  } do
    before = :sys.get_state(Hub).delivery

    for invalid <- [
          Map.put(payload, "message", "private-content"),
          Map.delete(payload, "phase"),
          Map.put(payload, "phase", "private-error"),
          Map.put(payload, "active_handlers", -1),
          Map.put(payload, "active_handlers", 65),
          Map.put(payload, "overdue_handlers", 3),
          Map.put(payload, "quarantine_bytes", 1_099_511_627_777),
          Map.put(payload, "sequence", 0),
          Map.put(payload, "sequence", 9_007_199_254_740_992),
          Map.put(payload, "quarantine_available", "yes")
        ] do
      assert conn |> auth() |> post("/api/client-runtime", invalid) |> json_response(400)
    end

    assert before == :sys.get_state(Hub).delivery
  end

  test "duplicate and old sequences do not refresh freshness or overwrite gauges", %{
    payload: payload
  } do
    assert {:ok, _} = Hub.client_runtime_report("ai-token", Map.put(payload, "sequence", 2))

    :sys.replace_state(Hub, fn s ->
      update_in(
        s.delivery.client_presence["assistant"].runtime_report.received_ms,
        &(&1 - 20_000)
      )
    end)

    before = :sys.get_state(Hub).delivery.client_presence

    assert {:ok, _} =
             Hub.client_runtime_report("ai-token", %{
               payload
               | "sequence" => 1,
                 "active_handlers" => 0,
                 "overdue_handlers" => 0
             })

    assert {:ok, _} = Hub.client_runtime_report("ai-token", Map.put(payload, "sequence", 2))
    assert before == :sys.get_state(Hub).delivery.client_presence
    report = Exiron.Hub.ClientPresence.snapshot(:sys.get_state(Hub), "assistant").runtime
    assert report.active_handlers == 2
    assert report.stale
    assert report.status == "stale"
    assert report.age_ms >= 20_000
  end

  test "expired HTTP reports remain diagnostic without refreshing a lease and same-ID replacement rotates the fence",
       %{
         payload: payload
       } do
    client = :sys.get_state(Hub).delivery.clients["assistant"]
    Process.cancel_timer(client.timer)
    assert {:ok, _} = Hub.client_runtime_report("ai-token", payload)
    assert :sys.get_state(Hub).delivery.clients["assistant"] == client
    inactive = Exiron.Hub.ClientPresence.snapshot(:sys.get_state(Hub), "assistant").runtime
    assert inactive.status == "session_inactive"
    assert inactive.stale
    {:ok, next} = Hub.poll_delivery("ai-token", client_id: "worker")
    refute next.runtime_ref == payload["runtime_ref"]
    assert {:error, :client_lease_lost} = Hub.client_runtime_report("ai-token", payload)

    assert {:ok, _} =
             Hub.client_runtime_report("ai-token", %{payload | "runtime_ref" => next.runtime_ref})

    current = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", "worker", current.lease})
    _ = :sys.get_state(Hub)
    report = Exiron.Hub.ClientPresence.snapshot(:sys.get_state(Hub), "assistant").runtime
    assert report.status == "session_inactive"
    assert report.stale
  end

  test "WebSocket replacement rejects late reports with the same client ID", %{payload: payload} do
    current = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", "worker", current.lease})
    _ = :sys.get_state(Hub)
    socket = Exiron.HubCase.start_socket_process()
    {:ok, first} = Hub.connect_socket("ai-token", client_id: "worker", pid: socket)

    assert {:ok, _} =
             Hub.client_runtime_report("ai-token", %{payload | "runtime_ref" => first.runtime_ref})

    replacement = Exiron.HubCase.start_socket_process()
    {:ok, next} = Hub.connect_socket("ai-token", client_id: "worker", pid: replacement)
    refute first.runtime_ref == next.runtime_ref
    assert Exiron.Hub.ClientPresence.snapshot(:sys.get_state(Hub), "assistant").runtime == nil

    assert {:error, :client_lease_lost} =
             Hub.client_runtime_report("ai-token", %{payload | "runtime_ref" => first.runtime_ref})

    assert {:ok, _} =
             Hub.client_runtime_report("ai-token", %{payload | "runtime_ref" => next.runtime_ref})
  end

  test "wrong client, fence and hook credential cannot write another client's report", %{
    conn: conn,
    payload: payload
  } do
    for body <- [Map.put(payload, "client_id", "other"), Map.put(payload, "runtime_ref", "other")] do
      assert conn |> auth() |> post("/api/client-runtime", body) |> json_response(409)
    end

    assert conn
           |> put_req_header("authorization", "Bearer wrong")
           |> post("/api/client-runtime", payload)
           |> json_response(401)

    assert Exiron.Hub.ClientPresence.snapshot(:sys.get_state(Hub), "assistant").runtime == nil
  end

  test "valid credentials for another hook cannot write or read this hook's report" do
    router = Exiron.HubCase.load_router!()

    :ok =
      Hub.configure(
        %{router | hooks: Map.put(router.hooks, "other", "other-token")},
        Exiron.Hub.Telegram.new([])
      )

    {:ok, first} = Hub.poll_delivery("ai-token", client_id: "worker")
    {:ok, second} = Hub.poll_delivery("other-token", client_id: "other-worker")

    assert {:error, :client_lease_lost} =
             Hub.client_runtime_report("other-token", payload(first.runtime_ref))

    assert {:ok, _} =
             Hub.client_runtime_report(
               "other-token",
               Map.put(payload(second.runtime_ref), "client_id", "other-worker")
             )

    {:ok, first_status} = Hub.status_for_token("ai-token")
    assert Enum.map(first_status.hooks, & &1.name) == ["assistant"]
    assert hd(first_status.hooks).client.runtime == nil
    {:ok, other_status} = Hub.status_for_token("other-token")
    assert Enum.map(other_status.hooks, & &1.name) == ["other"]
    assert hd(other_status.hooks).client.runtime.active_handlers == 2
  end

  defp payload(ref),
    do:
      File.read!("clients/contract/client_runtime_report.json")
      |> Jason.decode!()
      |> Map.put("runtime_ref", ref)

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer ai-token")
end
