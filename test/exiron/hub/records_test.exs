defmodule Exiron.Hub.RecordsTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{ClientSession, Delivery, SendCommand, SendTask}

  test "client session exposes complete transport defaults" do
    lease = make_ref()
    session = ClientSession.new("client", lease, nil)

    assert %ClientSession{
             client_id: "client",
             lease: lease,
             timer: nil,
             transport: :http,
             connected_at: nil
           } = session

    assert lease == session.lease
    assert session.pid == nil
    assert session.monitor == nil
    assert session.socket_delivery == nil
    assert session.http_delivery == nil
    assert session.listen? == false
  end

  test "delivery derives payload metadata" do
    items = [%{data: "one"}, %{data: "three"}]
    delivery = Delivery.new(items)

    assert %Delivery{ref: ref, items: ^items, count: 2, bytes: 8} = delivery
    assert is_binary(ref)
    assert Delivery.usage(%{socket_delivery: delivery}) == {2, 8}
    assert Delivery.usage(nil) == {0, 0}
  end

  test "send task stores callback metadata" do
    from = self()
    monitor = make_ref()
    pid = self()
    timer = make_ref()
    command = SendCommand.push(from, "assistant")
    task = SendTask.new(from, command, pid, monitor, timer)

    assert %SendTask{
             from: ^from,
             command: ^command,
             pid: ^pid,
             monitor: ^monitor,
             timer: ^timer
           } = task
  end
end
