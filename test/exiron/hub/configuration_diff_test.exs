defmodule Exiron.Hub.ConfigurationDiffTest do
  use ExUnit.Case, async: true
  alias Exiron.Hub.ConfigurationDiff

  test "credential changes remain visible without revealing old or new values" do
    before = "telegram:\n  token: old-secret\nhooks:\n  service: old-hook\n"
    after_source = "telegram:\n  token: new-secret\nhooks:\n  service: new-hook\n"
    assert {:ok, diff} = ConfigurationDiff.preview(before, after_source)
    assert diff.changed? and diff.semantic_changed?
    text = Enum.map_join(diff.lines, "\n", & &1.text)
    for secret <- ["old-secret", "new-secret", "old-hook", "new-hook"], do: refute(text =~ secret)
    assert Enum.any?(diff.lines, &(&1.kind == :ins and &1.text =~ "REDACTED: after"))
    assert Enum.any?(diff.lines, &(&1.kind == :del and &1.text =~ "REDACTED: before"))
  end

  test "redacts credentials reused in ordinary fields, including escaped values" do
    source = ~s(token: 'very"secret'\nname: 'very"secret'\n)
    assert {:ok, diff} = ConfigurationDiff.preview("{}", source)
    text = Enum.map_join(diff.lines, "\n", & &1.text)
    refute text =~ "very"
  end

  test "a malformed current source is omitted and malformed targets fail closed" do
    assert {:ok, diff} = ConfigurationDiff.preview("secret-token: [", "version: '1'\n")
    assert diff.note
    refute Enum.any?(diff.lines, &(&1.text =~ "secret-token"))
    assert {:error, message} = ConfigurationDiff.preview("{}", "secret-token: [")
    refute message =~ "secret-token"
  end

  test "format-only edits are distinguished and long unchanged context is compacted" do
    assert {:ok, %{changed?: true, semantic_changed?: false}} =
             ConfigurationDiff.preview("version: '1'\n", "version: '1'\n# comment\n")

    source = Enum.map_join(1..300, "\n", &"field_#{&1}: value")
    assert {:ok, diff} = ConfigurationDiff.preview(source, source <> "\nnew: value")
    refute diff.truncated?
    assert length(diff.lines) < 30
    assert Enum.any?(diff.lines, &(&1.kind == :ins))
  end
end
