defmodule ExironWeb.IdempotencyTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}
  import Exiron.Support.RouterHelper

  setup do
    parent = self()

    router =
      load_router!("idempotency", """
      aliases:
        telegram:
          home: 123
      routes:
        home:
          push: true
          middleware: [family]
      middlewares:
        family:
          routes:
            assistant:
              messages: ["/ai"]
            other:
              messages: ["/other"]
      hooks:
        assistant: "ai-token"
        other: "other-token"
      """)

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, message ->
            send(parent, {:sent, message.data, self()})

            if message.data in ["blocking", "will-timeout", "will-cancel"] do
              receive do
                :finish -> {:ok, %{message_id: 901}}
              after
                2000 -> {:error, :test_sender_timeout}
              end
            else
              {:ok, %{message_id: 901}}
            end
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hi", "bot-token"))
    {:ok, [request]} = Hub.poll("ai-token", client_id: "worker")
    %{id: request.req_id}
  end

  test "a completed response replays after pending state is gone and rejects changes", %{
    conn: conn,
    id: id
  } do
    payload = response(id, "reply", "hello")
    original = keyed(conn, "responses", payload)
    assert json_response(original, 200) == %{"ok" => true}
    assert_receive {:sent, "hello", _}
    assert keyed(conn, "responses", payload) |> json_response(200) == json_response(original, 200)

    assert keyed(conn, "responses", %{payload | data: Base.encode64("different")})
           |> json_response(409)
           |> Map.fetch!("code") == "idempotency_conflict"

    assert keyed(conn, "push", Map.delete(payload, :req_id))
           |> json_response(409)
           |> Map.fetch!("code") == "idempotency_conflict"

    refute_receive {:sent, _, _}
    cache = :sys.get_state(Hub).idempotency
    refute inspect(cache) =~ "hello"
    assert map_size(cache.running) == 0
  end

  test "concurrent duplicates return in progress without starting another send", %{
    conn: conn,
    id: id
  } do
    parent = self()
    payload = response(id, "concurrent", "blocking")

    task =
      start_supervised!(
        {Task, fn -> send(parent, {:original, keyed(conn, "responses", payload)}) end},
        restart: :temporary
      )

    assert_receive {:sent, "blocking", sender}, 1000
    duplicate = keyed(conn, "responses", payload)
    assert json_response(duplicate, 409)["code"] == "idempotency_in_progress"
    assert get_resp_header(duplicate, "retry-after") == ["1"]
    refute_receive {:sent, _, _}
    ref = Process.monitor(task)
    send(sender, :finish)
    assert_receive {:original, original}, 1000
    assert json_response(original, 200) == %{"ok" => true}
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
    assert keyed(conn, "responses", payload) |> json_response(200) == %{"ok" => true}
    refute_receive {:sent, _, _}
  end

  test "keys are scoped by hook and completed pushes replay during drain", %{conn: conn} do
    payload = %{datatype: "text", data: Base.encode64("push"), idempotency_key: "shared"}
    assert keyed(conn, "push", payload) |> json_response(200) == %{"ok" => true, "sent" => 1}
    assert_receive {:sent, "push", _}

    assert keyed(conn, "push", payload, "other-token") |> json_response(200) == %{
             "ok" => true,
             "sent" => 1
           }

    assert_receive {:sent, "push", _}
    {:ok, _} = Hub.start_drain()
    on_exit(fn -> Hub.resume_intake() end)
    assert keyed(conn, "push", payload) |> json_response(200) == %{"ok" => true, "sent" => 1}
    refute_receive {:sent, _, _}
  end

  test "partial updates and finalization use separate keys and old updates never edit again", %{
    conn: conn,
    id: id
  } do
    first = Map.put(response(id, "update-1", "one"), :final, false)
    second = Map.put(response(id, "update-2", "two"), :final, false)
    receipt = keyed(conn, "responses", first) |> json_response(200)
    assert_receive {:sent, "one", _}
    assert keyed(conn, "responses", second) |> json_response(200)
    assert_receive {:sent, "two", _}
    assert keyed(conn, "responses", first) |> json_response(200) == receipt
    refute_receive {:sent, _, _}
    final = Map.put(response(id, "final", "two"), :final, true)
    assert keyed(conn, "responses", final) |> json_response(200) == %{"ok" => true}
    assert_receive {:sent, "two", _}
    assert keyed(conn, "responses", final) |> json_response(200) == %{"ok" => true}
    refute_receive {:sent, _, _}
  end

  test "timeout outcomes remain cached without another Telegram attempt", %{conn: conn, id: id} do
    parent = self()
    payload = response(id, "timeout", "will-timeout")

    task =
      start_supervised!(
        {Task, fn -> send(parent, {:original, keyed(conn, "responses", payload)}) end},
        restart: :temporary
      )

    assert_receive {:sent, "will-timeout", sender}, 1000
    sender_ref = Process.monitor(sender)
    [{ref, _}] = :sys.get_state(Hub).delivery.sends |> Map.to_list()
    send(Hub, {:send_timeout, ref})
    assert_receive {:original, original}, 1000
    original_body = json_response(original, 504)
    assert keyed(conn, "responses", payload) |> json_response(504) == original_body
    assert_receive {:DOWN, ^sender_ref, :process, ^sender, _}
    _ = task
    refute_receive {:sent, _, _}
  end

  test "cancellation finalizes an in-flight receipt", %{conn: conn, id: id} do
    parent = self()
    payload = response(id, "cancelled", "will-cancel")

    start_supervised!(
      {Task, fn -> send(parent, {:original, keyed(conn, "responses", payload)}) end},
      restart: :temporary
    )

    assert_receive {:sent, "will-cancel", _}, 1000
    assert {:ok, _} = Hub.cancel("ai-token", id)
    assert_receive {:original, original}, 1000
    body = json_response(original, 409)
    assert body["code"] == "request_cancelled"
    assert keyed(conn, "responses", payload) |> json_response(409) == body
    refute_receive {:sent, _, _}
  end

  test "invalid keys and pre-admission failures do not reserve keys", %{conn: conn, id: id} do
    for key <- [nil, "", "spaces are invalid", String.duplicate("x", 129)] do
      assert keyed(conn, "responses", response(id, key, "hello")) |> json_response(400)
    end

    invalid = %{response(id, "fixable", "hello") | datatype: "invalid"}
    assert keyed(conn, "responses", invalid) |> json_response(400)
    assert map_size(:sys.get_state(Hub).idempotency.records) == 0
    assert keyed(conn, "responses", response(id, "fixable", "hello")) |> json_response(200)
  end

  test "a lost original caller still leaves a replayable completed receipt", %{conn: conn, id: id} do
    payload = response(id, "lost-caller", "blocking")

    task =
      start_supervised!({Task, fn -> keyed(conn, "responses", payload) end}, restart: :temporary)

    assert_receive {:sent, "blocking", sender}, 1000
    ref = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}
    :ok = Hub.subscribe_status()
    send(sender, :finish)
    assert_receive {:hub_status_delta, %{values: %{requested: 0}}}, 1000
    assert keyed(conn, "responses", payload) |> json_response(200) == %{"ok" => true}
    refute_receive {:sent, _, _}
  end

  test "partial push outcomes replay without resending confirmed parts", %{conn: conn} do
    parent = self()

    telegram =
      Telegram.new(
        [%{chat_id: 123, bot_token: "bot-token"}, %{chat_id: 456, bot_token: "bot-token"}],
        sender: fn _, message ->
          send(parent, {:part, message.chat_id})

          if message.chat_id == 123,
            do: {:ok, %{message_id: 901}},
            else: {:error, %ExGram.Error{code: 403}}
        end
      )

    :ok = Hub.configure(Exiron.HubCase.load_multi_push_router!(), telegram)
    payload = %{datatype: "text", data: Base.encode64("partial"), idempotency_key: "partial"}
    original = keyed(conn, "push", payload)
    body = json_response(original, original.status)
    assert original.status >= 400
    assert body["delivery"]["delivery_status"] == "partial"
    assert_receive {:part, 123}
    assert_receive {:part, 456}
    assert keyed(conn, "push", payload) |> json_response(original.status) == body
    refute_receive {:part, _}
  end

  defp response(id, key, text),
    do: %{req_id: id, datatype: "text", data: Base.encode64(text), idempotency_key: key}

  defp keyed(conn, operation, payload, token \\ "ai-token"),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post("/api/idempotent/" <> operation, payload)
end
