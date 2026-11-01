defmodule ExironClient.ContractScenariosTest do
  use ExUnit.Case, async: true

  alias ExironClient.{Auth, Error, Protocol, SocketError}

  @contract_dir Path.expand("../../contract", __DIR__)

  test "shared scenarios execute against the client protocol adapters" do
    manifest = json!("manifest.json")
    scenarios = Path.wildcard(Path.join(@contract_dir, "scenarios/*.json"))

    assert length(scenarios) == 8

    for path <- scenarios,
        scenario = path |> File.read!() |> Jason.decode!(),
        scenario_case <- scenario["cases"] do
      assert scenario["scenario_version"] == "1"
      execute_case(scenario_case, manifest)
    end
  end

  defp execute_case(scenario_case, manifest) do
    request = scenario_case["request"] || %{}
    response = scenario_case["response"] || %{}

    Enum.each(fixture_names(request) ++ fixture_names(response), fn fixture ->
      assert is_map(json!(fixture))
    end)

    if code = response["error_code"] do
      error =
        Error.from_response(response["status"] || 409, %{
          "code" => code,
          "error" => "changed message"
        })

      assert error.code == code
      assert Atom.to_string(error.reason) == code
    end

    if response["protocol_version"] == "manifest" do
      fixture = json!(response["response_fixture"] || response["frame_fixture"])

      protocol =
        if response["response_fixture"],
          do: fixture |> Auth.from_wire() |> Auth.protocol(),
          else: Protocol.from_wire(fixture)

      assert protocol.version == manifest["protocol_version"]
      assert protocol.capabilities == manifest["capabilities"]
    end

    if response["server_frame_type"] == "error" do
      frame = json!(response["frame_fixture"])
      error = SocketError.socket_error(frame["error"], frame)
      assert error.code == response["error_code"]
    end
  end

  defp fixture_names(value) do
    for {key, fixture} <- value,
        String.ends_with?(key, "_fixture"),
        is_binary(fixture),
        do: fixture
  end

  defp json!(name) do
    @contract_dir |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
