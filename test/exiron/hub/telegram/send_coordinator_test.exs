defmodule Exiron.Hub.Telegram.SendCoordinatorTest do
  use ExUnit.Case, async: true
  alias Exiron.Hub.Telegram.SendCoordinator

  setup do
    %{server: start_supervised!({SendCoordinator, name: __MODULE__})}
  end

  test "serializes one bot while other bots continue and releases a crashed owner", %{
    server: server
  } do
    parent = self()

    first =
      start_supervised!(
        {Task,
         fn ->
           SendCoordinator.run(
             "one",
             fn ->
               send(parent, {:entered, self()})

               receive do
                 :finish -> :ok
               end
             end,
             server: server
           )
         end},
        id: :first
      )

    assert_receive {:entered, ^first}

    _second =
      start_supervised!(
        {Task,
         fn ->
           result =
             SendCoordinator.run(
               "one",
               fn ->
                 send(parent, :second_entered)
                 :ok
               end,
               server: server
             )

           send(parent, {:second_result, result})
         end},
        id: :second
      )

    assert SendCoordinator.run("two", fn -> :independent end, server: server) == :independent
    refute_receive :second_entered
    monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first, :killed}
    assert_receive :second_entered
    assert_receive {:second_result, :ok}
  end

  test "cancelled queued callers never send after the active owner releases", %{server: server} do
    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           SendCoordinator.run(
             "queue",
             fn ->
               send(parent, :owner_entered)

               receive do
                 :release -> :ok
               end
             end,
             server: server
           )

           send(parent, :owner_finished)
         end},
        id: :owner
      )

    assert_receive :owner_entered, 1000

    key = :crypto.hash(:sha256, "queue")

    waiter =
      start_supervised!(
        {Task,
         fn ->
           # An asynchronous call lets the test observe a genuinely queued caller.
           request = :gen_server.send_request(server, {:acquire, key})
           send(parent, {:waiting, self()})

           case :gen_server.receive_response(request, :infinity) do
             {:reply, :ok} -> send(parent, :cancelled_caller_sent)
             _ -> :ok
           end
         end},
        id: :waiter
      )

    assert_receive {:waiting, ^waiter}
    # The request was sent before the notification; this barrier handles it.
    assert :sys.get_state(server).monitors |> map_size() == 2
    monitor = Process.monitor(waiter)
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, :killed}
    send(owner, :release)
    assert_receive :owner_finished
    assert :ok = SendCoordinator.run("queue", fn -> :ok end, server: server)
    refute_receive :cancelled_caller_sent
    assert :sys.get_state(server).monitors == %{}
  end

  test "honors an explicit retry delay and retries a rejected send", %{server: server} do
    parent = self()
    attempts = start_supervised!({Agent, fn -> 0 end})

    _sender =
      start_supervised!(
        {Task,
         fn ->
           result =
             SendCoordinator.run(
               "limited",
               fn ->
                 attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
                 send(parent, {:attempt, attempt})

                 if attempt == 1,
                   do:
                     {:error,
                      %ExGram.Error{code: 429, metadata: %{parameters: %{retry_after: 1}}}},
                   else: :ok
               end,
               server: server
             )

           send(parent, {:result, result})
         end},
        id: :sender
      )

    # Allow startup scheduling under suite load; retry timing is checked below.
    assert_receive {:attempt, 1}, 1000
    refute_receive {:attempt, 2}, 200
    assert_receive {:attempt, 2}, 1500
    assert_receive {:result, :ok}
    assert Agent.get(attempts, & &1) == 2
  end

  test "does not retry ambiguous failures or invalid hints", %{server: server} do
    for error <- [
          :timeout,
          %ExGram.Error{code: 500},
          %ExGram.Error{code: 429},
          %ExGram.Error{code: 429, metadata: %{parameters: %{retry_after: 0}}}
        ] do
      result =
        SendCoordinator.run(
          "single",
          fn ->
            send(self(), :attempt)
            {:error, error}
          end,
          server: server
        )

      assert result == {:error, error}
      assert_receive :attempt
      refute_receive :attempt
    end
  end

  test "the retry budget is finite and cooldown applies to other callers", %{server: server} do
    error = %ExGram.Error{code: 429, metadata: %{parameters: %{"retry_after" => 1}}}

    assert {:error, ^error} =
             SendCoordinator.run("bounded", fn -> {:error, error} end,
               server: server,
               max_retries: 0
             )

    key = :crypto.hash(:sha256, "bounded")
    state = :sys.get_state(server)
    assert state.bots[key].ready_at > System.monotonic_time(:millisecond)
    assert state.bots[key].owner == nil
    assert map_size(state.monitors) == 0
    refute inspect(state) =~ "bounded"
  end
end
