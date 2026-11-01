defmodule ExironClient.VersionTest do
  use ExUnit.Case, async: true

  test "SDK version matches its package metadata independently of protocol" do
    assert ExironClient.Version.current() == to_string(Application.spec(:exiron_client, :vsn))
    refute ExironClient.Version.current() == ExironClient.Protocol.current_version()
  end
end
