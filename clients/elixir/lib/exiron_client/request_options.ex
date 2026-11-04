defmodule ExironClient.RequestOptions do
  @moduledoc false

  # Req 0.7 moved Finch request options under :finch. Keep accepting the SDK's
  # existing Req options while allowing applications to resolve older Req releases.
  def nested_finch? do
    Version.compare(to_string(Application.spec(:req, :vsn)), "0.7.0") != :lt
  end

  def normalize(opts) do
    if nested_finch?(), do: normalize_finch(opts), else: opts
  end

  defp normalize_finch(opts) do
    finch =
      case Keyword.get(opts, :finch) do
        nil -> []
        name when is_atom(name) -> [name: name]
        options -> options
      end

    finch =
      case Keyword.fetch(opts, :pool_timeout) do
        {:ok, timeout} -> Keyword.put(finch, :pool_timeout, timeout)
        :error -> finch
      end

    legacy_pool_keys = [:connect_options, :inet6, :pool_max_idle_time]

    {opts, finch} =
      if Enum.any?(legacy_pool_keys, &Keyword.has_key?(opts, &1)) and
           not Keyword.has_key?(finch, :name) do
        pool = Req.Finch.pool_options(Map.new(opts))
        {Keyword.drop(opts, legacy_pool_keys), Keyword.merge(pool, finch)}
      else
        {opts, finch}
      end

    opts = Keyword.delete(opts, :pool_timeout)
    if finch == [], do: opts, else: Keyword.put(opts, :finch, finch)
  end
end
