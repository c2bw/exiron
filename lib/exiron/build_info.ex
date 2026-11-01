defmodule Exiron.BuildInfo do
  @moduledoc "Packaged release identity. Source builds report an unknown revision."
  @version_file Path.expand("../../VERSION", __DIR__)
  @external_resource @version_file
  @version @version_file |> File.read!() |> String.trim()
  @root Path.expand("../..", __DIR__)

  def current do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         version when is_binary(version) <- System.get_env("RELEASE_VSN"),
         {:ok, data} <- File.read(Path.join([root, "releases", version, "build-info.json"])),
         {:ok, manifest} <- Jason.decode(data) do
      from_manifest(manifest)
    else
      _ -> base(:unavailable)
    end
  end

  @doc false
  def from_manifest(manifest) when is_map(manifest) do
    if manifest["build_format"] == 1 and manifest["server_version"] == @version and
         manifest["protocol_version"] == Exiron.Protocol.protocol_version() and
         (is_nil(manifest["commit"]) or valid_commit?(manifest["commit"])) and
         manifest["dirty"] in [nil, true, false] do
      Map.merge(base(:available), %{commit: manifest["commit"], dirty: manifest["dirty"]})
    else
      base(:invalid)
    end
  end

  def from_manifest(_), do: base(:invalid)

  defp base(status),
    do: %{
      server_version: @version,
      protocol_version: Exiron.Protocol.protocol_version(),
      commit: nil,
      dirty: nil,
      metadata_status: status
    }

  @doc false
  def write_release(release) do
    unless release.version == @version, do: raise("release version must match VERSION")
    {git_commit, git_dirty} = git_identity()

    commit =
      case System.get_env("EXIRON_BUILD_COMMIT") do
        nil ->
          git_commit

        "" ->
          git_commit

        value ->
          if valid_commit?(value),
            do: value,
            else: raise("EXIRON_BUILD_COMMIT must be a full lowercase hexadecimal commit ID")
      end

    dirty =
      case System.get_env("EXIRON_BUILD_DIRTY") do
        nil -> if(commit == git_commit, do: git_dirty)
        "unknown" -> nil
        "true" -> true
        "false" -> false
        _ -> raise "EXIRON_BUILD_DIRTY must be true, false or unknown"
      end

    manifest = %{
      build_format: 1,
      server_version: @version,
      protocol_version: Exiron.Protocol.protocol_version(),
      commit: commit,
      dirty: dirty,
      elixir_version: System.version(),
      otp_release: System.otp_release()
    }

    path = Path.join([release.path, "releases", release.version, "build-info.json"])
    File.write!(path, Jason.encode!(manifest, pretty: true) <> "\n")
    release
  end

  defp valid_commit?(value),
    do: is_binary(value) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)

  defp git_identity do
    with {root, 0} <-
           System.cmd("git", ["rev-parse", "--show-toplevel"], cd: @root, stderr_to_stdout: true),
         true <- String.trim(root) == @root,
         {commit, 0} <-
           System.cmd("git", ["rev-parse", "--verify", "HEAD"], cd: @root, stderr_to_stdout: true),
         true <- valid_commit?(String.trim(commit)),
         {status, 0} <-
           System.cmd("git", ["status", "--porcelain"], cd: @root, stderr_to_stdout: true) do
      {String.trim(commit), String.trim(status) != ""}
    else
      _ -> {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end
end
