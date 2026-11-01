defmodule Exiron.ReleaseMetadata do
  @moduledoc false
  @components %{
    server: "VERSION",
    elixir_sdk: "clients/elixir/VERSION",
    go_sdk: "clients/go/VERSION"
  }

  def check!(root, opts \\ []) do
    versions =
      Map.new(@components, fn {component, path} ->
        version = root |> Path.join(path) |> File.read!() |> String.trim()

        parsed =
          case Version.parse(version) do
            {:ok, value} -> value
            :error -> raise "#{path} must contain a semantic package version"
          end

        if component == :go_sdk and parsed.build != nil,
          do: raise("Go SDK VERSION must not have build metadata")

        {component, version}
      end)

    manifest = json!(root, "clients/contract/manifest.json")
    protocol = manifest["protocol_version"]

    unless is_binary(protocol) and
             Regex.match?(~r/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/, protocol),
           do: raise("protocol_version must be major.minor")

    for name <- ["auth_response.json", "websocket_connected_frame.json"] do
      fixture = json!(root, "clients/contract/" <> name)

      unless fixture["server_version"] == versions.server and
               fixture["protocol_version"] == protocol,
             do: raise("#{name} version metadata does not match its authorities")
    end

    module =
      root
      |> Path.join("clients/go/go.mod")
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "module "))
      |> String.replace_prefix("module ", "")
      |> String.trim()

    {:ok, go_version} = Version.parse(versions.go_sdk)

    expected =
      "github.com/c2bw/exiron/clients/go" <>
        if(go_version.major >= 2, do: "/v#{go_version.major}", else: "")

    unless module == expected, do: raise("Go module path does not match SDK major version")
    tag = Keyword.get(opts, :tag)

    if tag do
      tags = %{
        "v#{versions.server}" => :server,
        "clients/elixir/v#{versions.elixir_sdk}" => :elixir_sdk,
        "clients/go/v#{versions.go_sdk}" => :go_sdk
      }

      unless Map.has_key?(tags, tag),
        do: raise("release tag does not match a component VERSION or tag prefix")
    end

    if path = Keyword.get(opts, :release) do
      build = json!(path, "releases/#{versions.server}/build-info.json")
      info = Exiron.BuildInfo.from_manifest(build)

      unless info.metadata_status == :available and build["server_version"] == versions.server and
               build["protocol_version"] == protocol,
             do: raise("release artifact identity does not match source versions")

      unless match?({:ok, _}, Version.parse(build["elixir_version"] || "")) and
               is_binary(build["otp_release"]) and
               Regex.match?(~r/\A[0-9]+(?:\.[0-9]+)*\z/, build["otp_release"]),
             do: raise("release artifact has invalid build toolchain metadata")

      if Keyword.get(opts, :require_clean, false) and (is_nil(info.commit) or info.dirty != false),
        do: raise("release artifact must identify a known clean commit")
    else
      if Keyword.get(opts, :require_clean, false), do: raise("--require-clean requires --release")
    end

    Map.put(versions, :protocol, protocol)
  end

  defp json!(root, path), do: root |> Path.join(path) |> File.read!() |> Jason.decode!()
end
