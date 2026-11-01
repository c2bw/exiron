defmodule Exiron.ReleaseMetadataTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    version = to_string(Application.spec(:exiron, :vsn))

    for path <- ["clients/elixir", "clients/go", "clients/contract"] do
      File.mkdir_p!(Path.join(root, path))
    end

    File.write!(Path.join(root, "VERSION"), version <> "\n")
    File.write!(Path.join(root, "clients/elixir/VERSION"), "0.2.0\n")
    File.write!(Path.join(root, "clients/go/VERSION"), "0.3.0\n")

    File.write!(
      Path.join(root, "clients/go/go.mod"),
      "module github.com/c2bw/exiron/clients/go\n"
    )

    fixture = %{server_version: version, protocol_version: Exiron.Protocol.protocol_version()}

    for name <- ["manifest.json", "auth_response.json", "websocket_connected_frame.json"] do
      File.write!(Path.join(root, "clients/contract/" <> name), Jason.encode!(fixture))
    end

    %{root: root, version: version}
  end

  test "component versions can differ and matching nested tags are accepted", %{
    root: root,
    version: version
  } do
    for tag <- ["v" <> version, "clients/elixir/v0.2.0", "clients/go/v0.3.0"] do
      assert Exiron.ReleaseMetadata.check!(root, tag: tag).go_sdk == "0.3.0"
    end

    assert_raise RuntimeError, fn -> Exiron.ReleaseMetadata.check!(root, tag: "v99.98.97") end
  end

  test "stale fixtures and malformed versions cannot pass", %{root: root, version: version} do
    parsed = Version.parse!(version)
    changed = %{parsed | patch: parsed.patch + 1, pre: [], build: nil} |> Version.to_string()
    File.write!(Path.join(root, "VERSION"), changed <> "\n")
    assert_raise RuntimeError, fn -> Exiron.ReleaseMetadata.check!(root) end
    File.write!(Path.join(root, "VERSION"), "not-a-version\n")
    assert_raise RuntimeError, fn -> Exiron.ReleaseMetadata.check!(root) end
  end

  test "Go major-version path and build metadata rules are enforced", %{
    root: root
  } do
    File.write!(Path.join(root, "clients/go/VERSION"), "2.0.0\n")
    assert_raise RuntimeError, fn -> Exiron.ReleaseMetadata.check!(root) end

    File.write!(
      Path.join(root, "clients/go/go.mod"),
      "module github.com/c2bw/exiron/clients/go/v2\n"
    )

    assert Exiron.ReleaseMetadata.check!(root).go_sdk == "2.0.0"
    File.write!(Path.join(root, "clients/go/VERSION"), "2.0.0+build\n")
    assert_raise RuntimeError, fn -> Exiron.ReleaseMetadata.check!(root) end
  end

  test "artifact provenance and clean release requirements are validated", %{
    root: root,
    version: version
  } do
    File.mkdir_p!(Path.join([root, "releases", version]))

    manifest = %{
      build_format: 1,
      server_version: version,
      protocol_version: Exiron.Protocol.protocol_version(),
      commit: String.duplicate("a", 40),
      dirty: false,
      elixir_version: System.version(),
      otp_release: System.otp_release()
    }

    path = Path.join([root, "releases", version, "build-info.json"])
    File.write!(path, Jason.encode!(manifest))
    assert Exiron.ReleaseMetadata.check!(root, release: root, require_clean: true)
    File.write!(path, Jason.encode!(%{manifest | dirty: true}))

    assert_raise RuntimeError, fn ->
      Exiron.ReleaseMetadata.check!(root, release: root, require_clean: true)
    end

    File.write!(path, Jason.encode!(%{manifest | commit: nil}))

    assert_raise RuntimeError, fn ->
      Exiron.ReleaseMetadata.check!(root, release: root, require_clean: true)
    end

    File.write!(path, Jason.encode!(%{manifest | server_version: "9.0.0"}))
    assert_raise RuntimeError, fn -> Exiron.ReleaseMetadata.check!(root, release: root) end
  end
end
