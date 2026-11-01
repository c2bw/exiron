defmodule ExironClient.Version do
  @moduledoc "SDK package version, independent of the negotiated wire protocol."
  @path Path.expand("../../VERSION", __DIR__)
  @external_resource @path
  @version @path |> File.read!() |> String.trim()
  def current, do: @version
end
