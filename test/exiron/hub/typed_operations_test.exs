defmodule Exiron.Hub.TypedOperationsTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Message, SendCommand, SendResult, SendTask}

  test "send commands carry explicit response, push, and background shapes" do
    from = {self(), make_ref()}
    message = Message.outgoing(222, 7, "text", "hello", "token", bot_name: "bot")

    assert %SendCommand{
             kind: :respond,
             from: ^from,
             request_id: "request-1",
             hook: "assistant",
             message: ^message
           } = SendCommand.respond(from, "request-1", :pending, "assistant", message)

    assert %SendCommand{kind: :push, from: ^from, hook: "assistant"} =
             SendCommand.push(from, "assistant")

    assert %SendCommand{kind: :overloaded, hook: "assistant", message: ^message} =
             SendCommand.background(:overloaded, "assistant", message)
  end

  test "send results normalize transport values into one typed result" do
    assert %SendResult{status: :ok, value: :sent} = SendResult.normalize({:ok, :sent})

    assert %SendResult{status: :error, reason: :offline} =
             SendResult.normalize({:error, :offline})

    assert %SendResult{
             status: :partial_error,
             reason: :offline,
             messages: [:sent],
             failures: [{:failed, :offline}]
           } = SendResult.normalize({:partial_error, :offline, [:sent], [{:failed, :offline}]})
  end

  test "send task retains its typed command" do
    command = SendCommand.push(nil, "assistant")
    task = SendTask.new(nil, command, self(), make_ref(), make_ref())

    assert task.command == command
  end
end
