defmodule Exiron.Hub.ClientIdentityTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.ClientIdentity

  test "HTTP contact reports package identity and older polls clear it" do
    assert {:ok, []} =
             Hub.poll("ai-token",
               client_id: "worker",
               client_identity: %{sdk: "go", version: "0.4.2-rc.1"}
             )

    assert presence().client_sdk == "go"
    assert presence().client_version == "0.4.2-rc.1"
    expire_client("assistant", "worker")
    assert presence().client_version == "0.4.2-rc.1"
    assert presence().state == "http_lease_expired"
    assert {:ok, []} = Hub.poll("ai-token", client_id: "older-worker")
    assert presence().client_version == nil
    assert presence().client_sdk == nil
  end

  test "socket replacement updates identity and preserves last observation on disconnect" do
    pid = start_socket_process()

    {:ok, _} =
      Hub.connect_socket("ai-token",
        client_id: "socket",
        pid: pid,
        client_identity: %{sdk: "elixir", version: "1.2.3"}
      )

    assert presence().client_version == "1.2.3"
    replacement = start_socket_process()

    {:ok, _} =
      Hub.connect_socket("ai-token",
        client_id: "socket",
        pid: replacement,
        client_identity: %{sdk: "go", version: "2.0.0"}
      )

    assert presence().client_sdk == "go" and presence().client_version == "2.0.0"
    :ok = Hub.disconnect_socket("assistant", "socket", replacement)
    assert presence().state == "websocket_disconnected"
    assert presence().client_version == "2.0.0"
  end

  test "malformed hints never become display metadata or reject an otherwise valid client" do
    for {sdk, version} <- [
          {"other", "0.1.0"},
          {"go", "not a version"},
          {"elixir", String.duplicate("x", 65)},
          {"go", "0.1.0\nsecret"},
          {nil, nil}
        ] do
      assert ClientIdentity.parse(sdk, version) == nil

      assert {:ok, []} =
               Hub.poll("ai-token",
                 client_id: "worker",
                 client_identity: %{sdk: sdk, version: version}
               )

      assert presence().client_version == nil
    end
  end

  defp presence, do: hd(Hub.status().hooks).client
end
