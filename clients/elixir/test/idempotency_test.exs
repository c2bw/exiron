defmodule ExironClient.IdempotencyTest do
  use ExUnit.Case, async: true
  alias ExironClient.Error

  test "keyed responses and pushes use dedicated routes and preserve errors without retries" do
    parent = self()

    client =
      client(fn request ->
        send(parent, {:request, request.url.path, request.options.json})

        Req.Response.json(%Req.Response{status: 409}, %{
          code: "idempotency_in_progress",
          error: "operation with this idempotency key is still running"
        })
      end)

    assert {:error, error} =
             ExironClient.respond(client, "req-1", "text", "hello", idempotency_key: "reply-1")

    assert Error.idempotency_in_progress?(error)
    assert_receive {:request, "/api/idempotent/responses", %{idempotency_key: "reply-1"}}
    assert {:error, _} = ExironClient.push(client, "text", "hello", idempotency_key: "push-1")
    assert_receive {:request, "/api/idempotent/push", %{idempotency_key: "push-1"}}

    assert {:error, _} =
             ExironClient.push(client, 123, "text", "hello", idempotency_key: "target-1")

    assert_receive {:request, "/api/idempotent/push",
                    %{idempotency_key: "target-1", chat_id: 123}}

    refute_receive {:request, _, _}
  end

  test "old servers return an error without a fallback mutation" do
    parent = self()

    client =
      client(fn request ->
        send(parent, {:request, request.url.path})
        Req.Response.json(%Req.Response{status: 404}, %{error: "not found"})
      end)

    assert {:error, _} =
             ExironClient.respond(client, "req-1", "text", "hello", idempotency_key: "key")

    assert_receive {:request, "/api/idempotent/responses"}
    refute_receive {:request, _}
  end

  test "stream derives separate stable keys for updates and finalization" do
    parent = self()

    client =
      client(fn request ->
        assert request.url.path == "/api/idempotent/responses"
        send(parent, {:key, request.options.json.idempotency_key})
        Req.Response.json(%{ok: true, message_id: 901})
      end)

    run = fn ->
      assert {:ok, _} =
               ExironClient.stream_text(client, "req-1", ["hello"],
                 idempotency_key: "stream-base"
               )

      assert_receive {:key, partial}
      assert_receive {:key, final}
      assert partial != final
      assert partial != "stream-base"
      {partial, final}
    end

    assert run.() == run.()
  end

  test "invalid keys and unsupported edit keys never send" do
    client = client(fn _ -> flunk("invalid option sent a request") end)

    for key <- ["", "not valid", String.duplicate("x", 129)] do
      assert {:error, %Error{reason: :invalid_payload}} =
               ExironClient.respond(client, "req-1", "text", "hello", idempotency_key: key)
    end

    assert {:error, %Error{reason: :invalid_payload}} =
             ExironClient.edit_text(client, "req-1", "edit", idempotency_key: "key")

    assert Error.idempotency_conflict?(%Error{reason: :idempotency_conflict})
    assert Error.idempotency_unavailable?(%Error{reason: :idempotency_capacity_exceeded})
    refute Error.idempotency_conflict?(nil)
  end

  defp client(response),
    do:
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [adapter: fn request -> {request, response.(request)} end]
      )
end
