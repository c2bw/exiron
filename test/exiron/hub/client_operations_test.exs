defmodule Exiron.Hub.ClientOperationsTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub.{
    AuthenticatedHook,
    ClientOperations,
    DeliveryState,
    QueueBuffer,
    Transition
  }

  alias Exiron.Secret
  import Exiron.Support.RouterHelper

  setup do
    %{router: load_router!("client-operations")}
  end

  test "authenticates configured hooks without mutating state", %{router: router} do
    state = %State{enabled?: true, router: router}

    assert %Transition{
             next_state: ^state,
             reply:
               {:ok, %{hook: "assistant", server_version: "test-version", auth_response: "OK"}},
             effects: []
           } = ClientOperations.authenticate(state, Secret.new("ai-token"), "test-version")

    assert %Transition{next_state: ^state, reply: {:error, :invalid_token}, effects: []} =
             ClientOperations.authenticate(state, Secret.new("wrong-token"), "test-version")

    assert %Transition{reply: {:error, :disabled}} =
             ClientOperations.authenticate(%{state | enabled?: false}, nil, "test-version")
  end

  test "poll returns queued messages and the renewed client state", %{router: router} do
    queued = %{msgtype: "listen", req_id: "listen-1"}

    state = %State{
      enabled?: true,
      router: router,
      delivery: %DeliveryState{queues: %{"assistant" => QueueBuffer.from_items([queued])}}
    }

    assert %Transition{
             reply: {:ok, [^queued]},
             next_state: next_state,
             effects: [%{kind: :broadcast_status}]
           } =
             ClientOperations.poll(state, Secret.new("ai-token"), client_id: "client")

    assert next_state.delivery.clients["assistant"].client_id == "client"
    assert QueueBuffer.items(next_state.delivery.queues["assistant"]) == []
    assert [%{action: "connected", hook: "assistant"}] = next_state.activity.client_events

    Process.cancel_timer(next_state.delivery.clients["assistant"].timer)
  end

  test "accepts a request-scoped authenticated hook without repeating token lookup", %{
    router: router
  } do
    state = %State{enabled?: true, router: router}

    assert %Transition{reply: {:ok, %{hooks: [%{name: "assistant"}]}}} =
             ClientOperations.status(
               state,
               Secret.new(AuthenticatedHook.new("assistant")),
               "test-version"
             )

    assert %Transition{reply: {:error, :invalid_token}} =
             ClientOperations.status(
               state,
               Secret.new(AuthenticatedHook.new("missing")),
               "test-version"
             )
  end

  test "rejects invalid response payloads before touching pending state", %{router: router} do
    state = %State{
      enabled?: true,
      router: router,
      delivery: %DeliveryState{pending: %{"request" => %{hook: "assistant"}}}
    }

    assert %Transition{next_state: ^state, reply: {:error, :invalid_datatype}, effects: []} =
             ClientOperations.respond(
               state,
               {self(), make_ref()},
               Secret.new("ai-token"),
               "request",
               "unknown",
               "payload",
               []
             )
  end

  test "rejects invalid UTF-8 text before touching pending state", %{router: router} do
    state = %State{
      enabled?: true,
      router: router,
      delivery: %DeliveryState{pending: %{"request" => %{hook: "assistant"}}}
    }

    assert %Transition{next_state: ^state, reply: {:error, :invalid_payload}, effects: []} =
             ClientOperations.respond(
               state,
               {self(), make_ref()},
               Secret.new("ai-token"),
               "request",
               "text",
               <<0xFF>>,
               []
             )
  end
end
