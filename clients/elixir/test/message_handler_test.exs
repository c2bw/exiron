defmodule ExironClient.MessageHandlerTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Message, MessageHandler, PollerOptions, SocketWorker}

  test "retries the failing request locally without replaying successful siblings" do
    counts = start_supervised!({Agent, fn -> %{} end})
    messages = for id <- ["one", "two", "three"], do: %Message{req_id: id}
    parent = self()

    handler = fn message ->
      count =
        Agent.get_and_update(counts, fn counts ->
          n = Map.get(counts, message.req_id, 0) + 1
          {n, Map.put(counts, message.req_id, n)}
        end)

      if message.req_id == "two" and count < 3, do: {:error, :transient}, else: :ok
    end

    assert :ok =
             MessageHandler.handle(messages, handler,
               max_attempts: 3,
               wait: fn _ -> :ok end,
               on_error: fn failure -> send(parent, {:failure, failure}) end
             )

    assert Agent.get(counts, & &1) == %{"one" => 1, "two" => 3, "three" => 1}
    assert_receive {:failure, %{request_id: "two", attempt: 1, will_retry?: true}}
    assert_receive {:failure, %{request_id: "two", attempt: 2, will_retry?: true}}
    refute_receive {:failure, _}
  end

  test "socket workers report exhausted requests without completing their delivery" do
    parent = self()

    worker =
      start_supervised!(%{
        id: SocketWorker,
        start:
          {SocketWorker, :start_link,
           [
             parent,
             fn _ -> {:error, :poison} end,
             [
               max_attempts: 2,
               wait: fn _ -> :ok end,
               on_error: fn failure -> send(parent, {:failure, failure}) end
             ]
           ]}
      })

    assert {:ok, ref} = SocketWorker.enqueue(worker, [%Message{req_id: "poison"}])
    assert_receive {:failure, %{request_id: "poison", attempt: 1, will_retry?: true}}, 1000
    assert_receive {:failure, %{request_id: "poison", attempt: 2, will_retry?: false}}, 1000
    assert_receive {:handler_failed, ^worker, ^ref, :poison}, 1000
    refute_receive {:handler_complete, _, _}
    assert {:error, :poison} = SocketWorker.enqueue(worker, [%Message{req_id: "later"}])
  end

  test "exceptions use the same bounded failure policy and invalid retry options are rejected" do
    parent = self()

    assert {:error, %RuntimeError{}} =
             MessageHandler.handle(
               [%Message{req_id: "broken"}],
               fn _ -> raise "handler failed" end,
               on_error: fn failure -> send(parent, failure) end
             )

    assert_receive %{request_id: "broken", attempt: 1, max_attempts: 1, will_retry?: false}

    for opts <- [
          [handler_max_attempts: 11],
          [handler_max_attempts: 0],
          [handler_retry_delay_ms: -1],
          [on_handler_error: :invalid]
        ] do
      assert_raise ArgumentError, fn ->
        PollerOptions.build!([client: %{}, handler: fn _ -> :ok end] ++ opts)
      end
    end
  end
end
