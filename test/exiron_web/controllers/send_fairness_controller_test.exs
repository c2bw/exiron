defmodule ExironWeb.SendFairnessControllerTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    parent = self()

    :ok =
      Hub.configure(
        Exiron.HubCase.load_push_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, message ->
            send(parent, {:attempt, message.data})

            if message.data == "hold" do
              send(parent, {:blocked, self()})

              receive do
                :release -> :ok
              end
            end

            {:ok, %{message_id: message.edit_message_id || 901}}
          end
        )
      )

    :sys.replace_state(Hub, fn s ->
      %{s | settings: %{s.settings | max_in_flight_sends: 2, max_in_flight_sends_per_hook: 1}}
    end)

    {:ok, []} = Hub.poll("ai-token")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request", bot_token: "bot-token")
      )

    {:ok, [req]} = Hub.poll("ai-token")
    %{request: req}
  end

  test "overload returns a retry hint and leaves the rejected response available", %{
    conn: conn,
    request: req
  } do
    parent = self()

    task =
      start_supervised!(
        {Task, fn -> send(parent, {:result, Hub.push("ai-token", "text", "hold", 123)}) end}
      )

    monitor = Process.monitor(task)
    assert_receive {:blocked, worker}
    payload = %{datatype: "text", data: Base.encode64("rejected"), req_id: req.req_id}
    response = conn |> auth() |> post("/api/responses", payload)
    assert get_resp_header(response, "retry-after") == ["1"]
    assert json_response(response, 503) == fixture("error_hook_send_queue_full.json")
    refute_received {:attempt, "rejected"}
    # Capacity responses apply to pushes too, including the legacy global code.
    response =
      conn
      |> auth()
      |> post("/api/push", %{datatype: "text", data: Base.encode64("rejected"), chat_id: 123})

    assert json_response(response, 503)["code"] == "hook_send_queue_full"
    :sys.replace_state(Hub, fn s -> %{s | settings: %{s.settings | max_in_flight_sends: 1}} end)
    response = conn |> auth() |> post("/api/responses", payload)
    assert get_resp_header(response, "retry-after") == ["1"]
    assert json_response(response, 503)["code"] == "send_queue_full"
    status = conn |> auth() |> get("/api/status") |> json_response(200)

    assert [
             %{
               "health" => %{
                 "in_flight_sends" => 1,
                 "in_flight_send_limit" => 1,
                 "send_capacity_rejections" => 3
               }
             }
           ] = status["hooks"]

    send(worker, :release)
    assert_receive {:result, {:ok, 1}}
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}

    assert conn |> auth() |> post("/api/responses", payload) |> json_response(200) == %{
             "ok" => true
           }

    assert_receive {:attempt, "rejected"}
  end

  test "byte rejection uses existing error codes before Telegram and exposes scoped usage", %{
    conn: conn,
    request: req
  } do
    :sys.replace_state(Hub, fn state ->
      %{state | settings: %{state.settings | max_in_flight_send_bytes_per_hook: 1}}
    end)

    payload = %{datatype: "text", data: Base.encode64("rejected"), req_id: req.req_id}
    response = conn |> auth() |> post("/api/responses", payload)
    assert json_response(response, 503) == fixture("error_hook_send_queue_full.json")
    assert get_resp_header(response, "retry-after") == ["1"]
    assert Map.has_key?(:sys.get_state(Hub).delivery.pending, req.req_id)
    refute_received {:attempt, _}

    :sys.replace_state(Hub, fn state ->
      %{state | settings: %{state.settings | max_in_flight_send_bytes: 1}}
    end)

    response = conn |> auth() |> post("/api/responses", payload)
    assert json_response(response, 503)["code"] == "send_queue_full"
    status = conn |> auth() |> get("/api/status") |> json_response(200)
    refute Map.has_key?(status, "send_capacity")

    assert [
             %{
               "health" => %{
                 "in_flight_send_bytes" => 0,
                 "in_flight_send_bytes_limit" => 1,
                 "send_byte_capacity_rejections" => 2
               }
             }
           ] = status["hooks"]

    assert Hub.status().send_capacity.bytes == 0
    refute_received {:attempt, _}
  end

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer ai-token")

  defp fixture(name),
    do: Path.join([File.cwd!(), "clients", "contract", name]) |> File.read!() |> Jason.decode!()
end
