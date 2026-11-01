defmodule Exiron.ContractConformanceTest do
  use ExUnit.Case, async: true

  alias Exiron.ContractFixtureValidation
  alias Exiron.Protocol
  alias ExironWeb.ClientSocket

  test "scenario catalog is language-neutral and complete" do
    scenario_ids = Protocol.scenarios() |> Enum.map(& &1["id"]) |> Enum.sort()

    assert scenario_ids == [
             "ambiguous_telegram_send_timeout",
             "authentication",
             "http_poll_delivery_acknowledgement",
             "protocol_capability_negotiation",
             "response_claim_errors",
             "retry_after_handling",
             "websocket_frame_size_rejection",
             "websocket_lifecycle"
           ]
  end

  test "shared executable lifecycle catalog covers both transports for every operation" do
    catalogs = Protocol.lifecycle_scenarios()
    assert Enum.map(catalogs, & &1["id"]) == ["managed_client_lifecycle"]

    actual =
      for catalog <- catalogs,
          scenario <- catalog["cases"],
          do: {scenario["transport"], scenario["operation"]}

    expected =
      for transport <- ~w(http websocket),
          operation <-
            ~w(failure_during_drain connection_loss_before_ack deadline_during_stream cancellation_during_stream quarantine_recovery_restart),
          do: {transport, operation}

    assert Enum.sort(actual) == Enum.sort(expected)
  end

  test "protocol builders produce the committed auth and connected fixtures" do
    auth =
      Protocol.auth_payload(%{
        auth_response: "OK",
        hook: "assistant",
        server_version: Exiron.Hub.server_version()
      })

    assert Jason.encode!(auth) |> Jason.decode!() ==
             ContractFixtureValidation.fixture_payload("auth_response.json")

    connected = %{
      hook: "assistant",
      client_id: "runner",
      runtime_ref: "runtime-session-1",
      listen: false,
      server_version: Exiron.Hub.server_version()
    }

    assert Protocol.connected_payload(connected) |> Jason.encode!() |> Jason.decode!() ==
             ContractFixtureValidation.fixture_payload("websocket_connected_frame.json")
  end

  test "protocol error and websocket builders expose stable contract fields" do
    assert Protocol.error_payload(:rate_limited) == %{
             code: "rate_limited",
             error: "too many requests"
           }

    assert ClientSocket.error_frame({:hook_already_connected, 12})
           |> decoded_frame() ==
             ContractFixtureValidation.fixture_payload("websocket_error_frame.json")
  end

  test "socket parser handles ping and ignores an acknowledgement for another delivery" do
    state = %{hook: "assistant", client_id: "runner", delivery_ref: "delivery-example"}

    assert {:push, pong, ^state} =
             ClientSocket.handle_in({Jason.encode!(%{type: "ping"}), [opcode: :text]}, state)

    assert decoded_frame(pong) ==
             ContractFixtureValidation.fixture_payload("websocket_pong_frame.json")

    assert {:ok, ^state} =
             ClientSocket.handle_in(
               {Jason.encode!(%{type: "ack", delivery_id: "other-delivery"}), [opcode: :text]},
               state
             )
  end

  defp decoded_frame({:text, payload}), do: Jason.decode!(payload)
end
