defmodule Exiron.Hub.BotLookupTasksTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.BotLookupTasks

  @event [:exiron, :hub, :lookup, :stop]

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    dispatcher =
      start_supervised!(
        {BotLookupTasks,
         [
           name: nil,
           task_supervisor: task_supervisor,
           max_concurrency: 2,
           max_queue: 3
         ]}
      )

    {:ok, dispatcher: dispatcher}
  end

  test "limits active lookup tasks and rejects work beyond the bounded queue", %{
    dispatcher: dispatcher
  } do
    parent = self()

    resolver = fn item ->
      send(parent, {:lookup_started, item, self()})

      receive do
        {:release, ^item} -> {:ok, item}
      end
    end

    message = fn item, result -> {:lookup_complete, item, result} end

    assert :ok = BotLookupTasks.start(1..5, resolver, message, dispatcher: dispatcher)

    assert_receive {:lookup_started, first, first_pid}
    assert_receive {:lookup_started, second, second_pid}
    assert first != second
    refute_receive {:lookup_started, _item, _pid}, 25

    assert_receive {:lookup_complete, 4, {:error, :lookup_queue_full}}
    assert_receive {:lookup_complete, 5, {:error, :lookup_queue_full}}

    send(first_pid, {:release, first})
    send(second_pid, {:release, second})

    assert_receive {:lookup_complete, ^first, {:ok, ^first}}
    assert_receive {:lookup_complete, ^second, {:ok, ^second}}
    assert_receive {:lookup_started, 3, third_pid}
    send(third_pid, {:release, 3})
    assert_receive {:lookup_complete, 3, {:ok, 3}}
  end

  test "emits duration and bounded outcome metadata for lookup failures", %{
    dispatcher: dispatcher
  } do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             BotLookupTasks.start(
               ["secret-token"],
               fn _item -> {:error, :timeout} end,
               fn item, result -> {:lookup_complete, item, result} end,
               dispatcher: dispatcher
             )

    assert_receive {:lookup_complete, "secret-token", {:error, :timeout}}
    assert_receive {:telemetry, @event, %{duration: duration}, metadata}
    assert metadata == %{outcome: :error}
    assert is_integer(duration) and duration >= 0
  end
end
