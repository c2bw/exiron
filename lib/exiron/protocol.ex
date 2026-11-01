defmodule Exiron.Protocol do
  @moduledoc false

  @manifest_path Path.expand("../../clients/contract/manifest.json", __DIR__)
  @scenarios_path Path.expand("../../clients/contract/scenarios", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()

  @errors Map.fetch!(@manifest, "errors")
  @websocket Map.get(@manifest, "websocket")
  @server_frame_types Map.get(@websocket, "server_frame_types")
  @error_code_by_reason for {code, descriptor} <- @errors,
                            reason <- Map.get(descriptor, "reasons", []),
                            into: %{},
                            do: {reason, code}

  def manifest, do: @manifest

  def protocol_version, do: Map.fetch!(@manifest, "protocol_version")
  def capabilities, do: Map.fetch!(@manifest, "capabilities")
  def datatypes, do: Map.fetch!(@manifest, "datatypes")
  def error_codes, do: Map.keys(@errors)

  def fixture_requirements do
    Map.fetch!(@manifest, "fixtures")
  end

  def http_fixtures, do: Map.fetch!(fixture_requirements(), "http")
  def websocket_fixtures, do: Map.fetch!(fixture_requirements(), "websocket")

  def scenario_files do
    @scenarios_path
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  def scenarios do
    Enum.map(scenario_files(), fn file ->
      file
      |> File.read!()
      |> Jason.decode!()
    end)
  end

  def lifecycle_scenarios do
    @scenarios_path
    |> Path.join("../lifecycle/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn file -> file |> File.read!() |> Jason.decode!() end)
  end

  def websocket_server_frame_types do
    Map.get(@websocket, "server_frame_types")
  end

  def websocket_client_frame_types do
    Map.get(@websocket, "client_frame_types")
  end

  def websocket_server_frame_type(type) when is_atom(type),
    do: websocket_server_frame_type(Atom.to_string(type))

  def websocket_server_frame_type(type) when type in @server_frame_types, do: type

  def websocket_server_frame_type(type),
    do: raise(ArgumentError, "unknown WebSocket server frame type: #{inspect(type)}")

  def error_code(reason) when is_atom(reason) do
    Map.get(@error_code_by_reason, Atom.to_string(reason), "internal_error")
  end

  def error_code(_reason), do: "internal_error"

  def error_descriptor(reason) do
    code = error_code(reason)
    descriptor = Map.fetch!(@errors, code)

    %{code: code, status: descriptor["status"], message: descriptor["message"]}
  end

  def error_message({:hook_already_connected, _retry_after_ms}),
    do: error_message(:hook_already_connected)

  def error_message(reason), do: error_descriptor(reason).message

  def error_payload(reason, extra \\ %{}) when is_map(extra) do
    descriptor = error_descriptor(reason)
    Map.merge(%{code: descriptor.code, error: descriptor.message}, extra)
  end

  def auth_payload(result) when is_map(result) do
    Map.merge(result, %{
      msgtype: "auth",
      protocol_version: protocol_version(),
      capabilities: capabilities()
    })
  end

  def connected_payload(connected) when is_map(connected) do
    %{
      type: websocket_server_frame_type(:connected),
      hook: connected.hook,
      client_id: connected.client_id,
      runtime_ref: Map.get(connected, :runtime_ref),
      listen: listen_payload(connected.listen),
      server_version: connected.server_version,
      protocol_version: protocol_version(),
      capabilities: capabilities()
    }
  end

  def websocket_error_payload({:hook_already_connected, retry_after_ms}) do
    error_payload(:hook_already_connected, %{
      type: websocket_server_frame_type(:error),
      retry_after_ms: retry_after_ms
    })
  end

  def websocket_error_payload(reason),
    do: error_payload(reason, %{type: websocket_server_frame_type(:error)})

  defp listen_payload(:all), do: "all"
  defp listen_payload(listen), do: listen
end
