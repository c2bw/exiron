defmodule ExironClient.Lease do
  @moduledoc "Cooperative HTTP batch lease-loss notification for opt-in managed handlers."
  @derive {Inspect, only: [:delivery_id]}
  defstruct [:delivery_id, :flag, :handlers]
  @key :exiron_client_lease

  def current, do: Process.get(@key)
  def lost?(token \\ current())
  def lost?(%__MODULE__{flag: flag}), do: :atomics.get(flag, 1) == 1
  def lost?(_), do: false

  @doc false
  def error,
    do: ExironClient.Error.new(:client_lease_lost, "HTTP client lease could not be confirmed")

  @doc false
  def with_handler(nil, fun), do: fun.()

  def with_handler(token, fun) do
    previous = Process.put(@key, token)
    :ets.insert(token.handlers, {self()})

    try do
      if lost?(token), do: {:error, error()}, else: fun.()
    after
      try do
        :ets.delete(token.handlers, self())
      rescue
        ArgumentError -> :ok
      end

      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc false
  def mark_lost(token, owner) do
    :atomics.put(token.flag, 1, 1)

    pids =
      :ets.tab2list(token.handlers) |> Enum.map(&elem(&1, 0)) |> MapSet.new() |> MapSet.put(owner)

    Enum.each(pids, &send(&1, {:exiron_client_lease_lost, token.delivery_id}))
    :ok
  end
end
