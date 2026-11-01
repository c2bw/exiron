defmodule ExironWeb.ClientSocketTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub
  alias Exiron.Hub.AuthenticatedHook
  alias Exiron.Hub.Telegram
  alias ExironWeb.ClientSocket
  import Exiron.Support.RouterHelper

  setup do
    :ok = Hub.configure(load_router!("client-socket"), Telegram.new([]))
  end

  test "initializes authenticated sockets and rejects invalid credentials" do
    assert {:push, [{:text, connected}, {:text, messages}], state} =
             ClientSocket.init(%{token: "ai-token", client_id: "socket", listen: false})

    assert %{hook: "assistant", client_id: "socket", delivery_ref: nil} = state
    assert %{"type" => "connected", "hook" => "assistant"} = Jason.decode!(connected)
    assert %{"type" => "messages", "messages" => []} = Jason.decode!(messages)

    assert :ok = ClientSocket.terminate(:normal, state)

    assert {:stop, :normal, {4009, "invalid token"}, {:text, error}, %{}} =
             ClientSocket.init(%{token: "invalid", client_id: "socket", listen: false})

    assert %{"code" => "invalid_token", "error" => "invalid token"} = Jason.decode!(error)
  end

  test "socket initialization retains the reported SDK package version" do
    assert {:push, _, state} =
             ClientSocket.init(%{
               token: "ai-token",
               client_id: "versioned-socket",
               listen: false,
               client_identity: %{sdk: "elixir", version: "0.1.0"}
             })

    assert [%{client: %{client_sdk: "elixir", client_version: "0.1.0"}}] = Hub.status().hooks
    assert :ok = ClientSocket.terminate(:normal, state)
  end

  test "application ping updates identified contact without changing its pong frame" do
    assert {:push, _, state} =
             ClientSocket.init(%{token: "ai-token", client_id: "socket", listen: false})

    assert {:push, {:text, pong}, ^state} =
             ClientSocket.handle_in({Jason.encode!(%{type: "ping"}), [opcode: :text]}, state)

    assert Jason.decode!(pong) == %{"type" => "pong"}
    _ = :sys.get_state(Hub)
    assert [%{client: %{last_contact_kind: "ping"}}] = Hub.status().hooks
    assert :ok = ClientSocket.terminate(:normal, state)
  end

  test "retains a delivery until the client explicitly acknowledges it" do
    delivery_ref = "delivery-1"
    messages = [%{msgtype: "listen", datatype: "text", data: Base.encode64("hello")}]
    state = %{hook: "assistant", client_id: "socket", delivery_ref: nil}

    assert {:push, {:text, payload}, next_state} =
             ClientSocket.handle_info({:exiron_messages, delivery_ref, messages}, state)

    assert next_state.delivery_ref == delivery_ref

    assert %{
             "type" => "messages",
             "delivery_id" => ^delivery_ref,
             "messages" => [%{"msgtype" => "listen", "datatype" => "text"}]
           } = Jason.decode!(payload)

    refute_receive _message

    ack = Jason.encode!(%{type: "ack", delivery_id: delivery_ref})

    assert {:ok, %{delivery_ref: nil}} =
             ClientSocket.handle_in({ack, [opcode: :text]}, next_state)
  end

  test "initializes with a request-scoped authenticated hook" do
    assert {:push, [{:text, connected}, {:text, _messages}], state} =
             ClientSocket.init(%{
               credential: AuthenticatedHook.new("assistant"),
               client_id: "socket",
               listen: false
             })

    assert %{"hook" => "assistant", "type" => "connected"} = Jason.decode!(connected)
    assert :ok = ClientSocket.terminate(:normal, state)
  end

  test "ignores stale delivery acknowledgements" do
    state = %{hook: "assistant", client_id: "socket", delivery_ref: "current"}
    ack = Jason.encode!(%{type: "ack", delivery_id: "stale"})

    assert {:ok, ^state} = ClientSocket.handle_in({ack, [opcode: :text]}, state)
  end

  test "handles protocol fallbacks and replacement notifications" do
    state = %{hook: "assistant", client_id: "socket", delivery_ref: nil}

    assert {:ok, ^state} = ClientSocket.handle_in({"not-json", [opcode: :text]}, state)

    assert {:ok, ^state} =
             ClientSocket.handle_in({Jason.encode!(%{type: "unknown"}), [opcode: :text]}, state)

    assert {:ok, ^state} = ClientSocket.handle_info(:unknown, state)

    assert {:stop, :normal, {1000, "replaced"}, ^state} =
             ClientSocket.handle_info({:exiron_socket_replaced, self()}, state)

    assert :ok = ClientSocket.terminate(:normal, %{})
  end
end
