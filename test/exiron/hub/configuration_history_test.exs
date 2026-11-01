defmodule Exiron.Hub.ConfigurationHistoryTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Configuration, ConfigurationHistory, ConfigurationService}
  alias Exiron.Support.TempPath

  setup do
    %{path: TempPath.tmp_path("configuration-history")}
  end

  test "retains distinct revisions privately and pins the last activated source", %{path: path} do
    active = Configuration.empty_source()
    assert {:ok, active_id} = ConfigurationHistory.checkpoint(path, active, activated: true)

    for n <- 1..25 do
      assert {:ok, _} = ConfigurationHistory.checkpoint(path, active <> "\n# revision #{n}\n")
    end

    assert {:ok, records} = ConfigurationHistory.list(path)
    assert length(records) == ConfigurationHistory.limit()
    assert Enum.any?(records, &(&1.id == active_id and &1.activated_at))
    refute Enum.any?(records, &Map.has_key?(&1, :source))
    assert {:ok, ^active} = ConfigurationHistory.fetch(path, active_id)
    assert {:ok, ^active_id} = ConfigurationHistory.checkpoint(path, active)
    assert {:ok, records} = ConfigurationHistory.list(path)
    assert length(records) == 20
    assert Bitwise.band(File.stat!(ConfigurationHistory.directory(path)).mode, 0o777) == 0o700

    for record <- records do
      file = Path.join(ConfigurationHistory.directory(path), record.id <> ".json")
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    end
  end

  test "rollback restores a validated revision over invalid YAML and preserves the overwritten bytes",
       %{path: path} do
    old = Configuration.empty_source()
    File.write!(path, old)

    assert {:ok, %{reload: :ok}} =
             ConfigurationService.save_and_reload(path, old <> "\n# new\n", reload: fn -> :ok end)

    broken = "telegram: [\n"
    File.write!(path, broken)
    id = ConfigurationHistory.digest(old)

    assert {:ok, %{reload: {:error, :disabled}}} =
             ConfigurationService.rollback(path, id, reload: fn -> {:error, :disabled} end)

    assert File.read!(path) == old
    assert {:ok, ^broken} = ConfigurationHistory.fetch(path, ConfigurationHistory.digest(broken))
    assert {:ok, records} = ConfigurationHistory.list(path)
    assert Enum.any?(records, &(&1.id == ConfigurationHistory.digest(broken) and not &1.valid?))
    assert {:error, _} = ConfigurationService.rollback(path, ConfigurationHistory.digest(broken))
    assert File.read!(path) == old
  end

  test "an unavailable history directory prevents overwriting the current file", %{path: path} do
    source = Configuration.empty_source()
    File.write!(path, source)
    File.write!(ConfigurationHistory.directory(path), "not a directory")

    assert {:error, {:configuration_history, _}} =
             ConfigurationService.save_and_reload(path, source <> "\n# change",
               reload: fn -> flunk("must not reload") end
             )

    assert File.read!(path) == source
  end

  test "rejects traversal, corrupted records and symlink directories", %{path: path} do
    source = Configuration.empty_source()
    assert {:ok, id} = ConfigurationHistory.checkpoint(path, source)
    assert {:error, :invalid_revision} = ConfigurationHistory.fetch(path, "../config")
    record = Path.join(ConfigurationHistory.directory(path), id <> ".json")
    File.write!(record, "{}")
    assert {:error, :invalid_revision} = ConfigurationHistory.fetch(path, id)
    assert {:ok, []} = ConfigurationHistory.list(path)

    another = TempPath.tmp_path("history-link")
    File.ln_s!(ConfigurationHistory.directory(path), ConfigurationHistory.directory(another))
    assert {:error, :unsafe_history_directory} = ConfigurationHistory.checkpoint(another, source)
  end

  test "checks the current source before restoring a reviewed revision", %{path: path} do
    source = Configuration.empty_source()
    assert {:ok, id} = ConfigurationHistory.checkpoint(path, source)
    newer = source <> "\n# changed elsewhere"
    File.write!(path, newer)

    assert {:error, %Exiron.Hub.RouteConfiguration.ConflictError{}} =
             ConfigurationService.rollback(path, id,
               expected_source: source,
               reload: fn -> flunk("must not reload stale source") end
             )

    assert File.read!(path) == newer
  end
end
