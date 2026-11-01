defmodule Exiron.Hub.Telegram.RejectionSuppressionTest do
  use ExUnit.Case, async: true
  import Exiron.Support.Eventually
  alias Exiron.Hub.Telegram.{RejectionCache, SendCoordinator}

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})

    server =
      start_supervised!(
        {SendCoordinator,
         name: __MODULE__, clock: fn -> Agent.get(clock, & &1) end, rejection_cooldown_ms: 100}
      )

    %{server: server, clock: clock}
  end

  test "401 suppresses the token across chats and a successful expiry probe confirms recovery", %{
    server: server,
    clock: clock
  } do
    error = %ExGram.Error{code: 401, message: "private rejection body secret-token"}
    assert run(server, "secret-token", 123, fn -> {:error, error} end) == {:error, error}

    assert {:error, %ExGram.Error{code: 401, metadata: %{exiron_suppressed: true}}} =
             run(server, "secret-token", 456, fn -> flunk("suppressed sender ran") end)

    assert :ok = run(server, "other-token", 123, fn -> :ok end)
    snapshot = SendCoordinator.snapshot(server)
    assert snapshot.active == 1 and snapshot.suppressed_attempts == 1
    refute inspect(snapshot) =~ "secret-token"
    refute inspect(:sys.get_state(server)) =~ "private rejection body"
    Agent.update(clock, fn _ -> 100 end)
    assert :ok = run(server, "secret-token", 456, fn -> :ok end)
    assert %{active: 0, probes: 1, recoveries: 1, records: []} = SendCoordinator.snapshot(server)
  end

  test "403 suppresses only the matching token and chat", %{server: server} do
    assert {:error, _} = run(server, "one", 123, fn -> {:error, %ExGram.Error{code: 403}} end)
    assert :ok = run(server, "one", 456, fn -> :ok end)
    assert :ok = run(server, "two", 123, fn -> :ok end)

    assert {:error, %ExGram.Error{code: 403}} =
             run(server, "one", 123, fn -> flunk("wrong scope") end)

    assert SendCoordinator.snapshot(server).suppressed_attempts == 1
  end

  test "timeouts, server errors and uncertain probes do not manufacture rejections", %{
    server: server,
    clock: clock
  } do
    for error <- [
          :timeout,
          %ExGram.Error{code: 500},
          %ExGram.Error{code: 400},
          %ExGram.Error{code: 429}
        ] do
      assert {:error, ^error} = run(server, "one", 123, fn -> {:error, error} end)
      assert SendCoordinator.snapshot(server).records == []
    end

    assert {:error, _} = run(server, "one", 123, fn -> {:error, %ExGram.Error{code: 401}} end)
    Agent.update(clock, fn _ -> 100 end)
    assert {:error, :timeout} = run(server, "one", 123, fn -> {:error, :timeout} end)
    assert %{recoveries: 0, records: []} = SendCoordinator.snapshot(server)
    assert {:error, _} = run(server, "one", 123, fn -> {:error, %ExGram.Error{code: 401}} end)
    Agent.update(clock, fn _ -> 200 end)

    assert_raise RuntimeError, "private exception", fn ->
      run(server, "one", 123, fn -> raise "private exception" end)
    end

    assert %{recoveries: 0, records: []} = SendCoordinator.snapshot(server)
  end

  test "queued callers are suppressed after the owner rejects, and expiry admits one retry probe",
       %{server: server, clock: clock} do
    parent = self()

    owner =
      task(fn ->
        run(server, "one", 123, fn ->
          send(parent, :entered)
          receive do: (:release -> {:error, %ExGram.Error{code: 401}})
        end)
      end)

    assert_receive :entered, 1000

    waiters =
      for _ <- 1..3 do
        task(fn ->
          run(server, "one", 123, fn -> flunk("queued sender bypassed suppression") end)
        end)
      end

    assert_eventually(fn -> assert map_size(:sys.get_state(server).monitors) == 4 end)
    send(owner, :release)
    assert_receive {:result, ^owner, {:error, %ExGram.Error{code: 401}}}, 1000

    for waiter <- waiters do
      assert_receive {:result, ^waiter,
                      {:error, %ExGram.Error{metadata: %{exiron_suppressed: true}}}},
                     1000
    end

    Agent.update(clock, fn _ -> 100 end)

    probe =
      task(fn ->
        run(server, "one", 123, fn ->
          send(parent, :probe)
          receive do: (:release -> {:error, %ExGram.Error{code: 401}})
        end)
      end)

    assert_receive :probe, 1000
    follower = task(fn -> run(server, "one", 123, fn -> flunk("second probe ran") end) end)
    assert_eventually(fn -> assert map_size(:sys.get_state(server).monitors) == 2 end)
    send(probe, :release)
    assert_receive {:result, ^probe, {:error, %ExGram.Error{code: 401}}}, 1000

    assert_receive {:result, ^follower,
                    {:error, %ExGram.Error{metadata: %{exiron_suppressed: true}}}},
                   1000

    assert %{probes: 1, rejections: 2, suppressed_attempts: 4} = SendCoordinator.snapshot(server)
  end

  test "cache is bounded and an expired token entry cannot bypass a live chat rejection" do
    cache = %RejectionCache{limit: 2, cooldown_ms: 100}

    cache =
      RejectionCache.record(cache, "digest", 123, "bot", {:error, %ExGram.Error{code: 401}}, 0)

    cache =
      RejectionCache.record(cache, "digest", 123, "bot", {:error, %ExGram.Error{code: 403}}, 50)

    assert {:blocked, 403, _} = RejectionCache.check(cache, "digest", 123, 100)

    cache =
      RejectionCache.record(cache, "other", 123, "bot", {:error, %ExGram.Error{code: 403}}, 100)

    assert map_size(cache.entries) == 2
    refute Map.has_key?(cache.entries, {:token, "digest"})
  end

  defp run(server, token, chat, fun),
    do: SendCoordinator.run(token, fun, server: server, chat_id: chat, bot_name: "worker")

  defp task(fun) do
    parent = self()

    start_supervised!({Task, fn -> send(parent, {:result, self(), fun.()}) end},
      id: make_ref(),
      restart: :temporary
    )
  end
end
