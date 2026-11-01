defmodule Exiron.BuildInfoTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  test "release manifests expose only validated identity and reject wrong artifacts" do
    manifest = %{
      "build_format" => 1,
      "server_version" => to_string(Application.spec(:exiron, :vsn)),
      "protocol_version" => Exiron.Protocol.protocol_version(),
      "commit" => String.duplicate("a", 40),
      "dirty" => false,
      "secret" => "private"
    }

    info = Exiron.BuildInfo.from_manifest(manifest)
    assert info.commit == String.duplicate("a", 40)
    assert info.metadata_status == :available
    refute Map.has_key?(info, :secret)

    for invalid <- [
          Map.put(manifest, "commit", "private"),
          Map.put(manifest, "dirty", "false"),
          Map.put(manifest, "server_version", "99.0.0"),
          %{}
        ] do
      assert %{commit: nil, dirty: nil, metadata_status: :invalid} =
               Exiron.BuildInfo.from_manifest(invalid)
    end
  end

  test "assembly writes metadata into the versioned release artifact", %{tmp_dir: root} do
    version = to_string(Application.spec(:exiron, :vsn))
    File.mkdir_p!(Path.join([root, "releases", version]))
    release = %{path: root, version: version}
    assert ^release = Exiron.BuildInfo.write_release(release)

    manifest =
      Path.join([root, "releases", version, "build-info.json"]) |> File.read!() |> Jason.decode!()

    assert Exiron.BuildInfo.from_manifest(manifest).metadata_status == :available
    assert manifest["elixir_version"] == System.version()
  end
end
