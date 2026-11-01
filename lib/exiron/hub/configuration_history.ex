defmodule Exiron.Hub.ConfigurationHistory do
  @moduledoc false
  require Logger

  alias Exiron.Hub.Configuration
  @limit 20
  @id_pattern ~r/\A[0-9a-f]{64}\z/

  def limit, do: @limit
  def directory(path), do: Path.join(Path.dirname(path), ".#{Path.basename(path)}.exiron-history")
  def digest(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  def list(path), do: locked(path, fn -> list_records(path) |> metadata_result() end)

  def fetch(path, id) when is_binary(id) do
    if Regex.match?(@id_pattern, id) do
      locked(path, fn ->
        with :ok <- safe_directory(path), {:ok, record} <- read_record(path, id) do
          {:ok, record.source}
        end
      end)
    else
      {:error, :invalid_revision}
    end
  end

  def fetch(_path, _id), do: {:error, :invalid_revision}

  def checkpoint(path, source, opts \\ []) when is_binary(source) do
    locked(path, fn ->
      with :ok <- ensure_directory(path),
           {:ok, records} <- list_records(path) do
        id = digest(source)
        previous = Enum.find(records, &(&1.id == id))
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        record = %{
          "version" => 1,
          "id" => id,
          "source_base64" => Base.encode64(source),
          "saved_at" => if(previous && !opts[:saved], do: previous.saved_at, else: now),
          "activated_at" =>
            if(opts[:activated], do: now, else: previous && previous.activated_at),
          "valid" => valid_source?(source)
        }

        with :ok <- atomic_record(path, id, Jason.encode!(record)),
             {:ok, updated} <- list_records(path),
             :ok <- prune(path, updated) do
          {:ok, id}
        end
      end
    end)
  end

  # Activation must not fail merely because its history directory is unavailable.
  # Dashboard writes, in contrast, require a pre-change checkpoint before rename.
  def checkpoint_active(path, source) do
    case checkpoint(path, source, activated: true) do
      {:ok, _id} ->
        :ok

      {:error, _reason} ->
        Logger.warning("Configuration activated, but its history checkpoint could not be written")
        :ok
    end
  end

  defp valid_source?(source) do
    match?({:ok, _}, Configuration.read_source(source))
  rescue
    _ -> false
  end

  defp locked(path, fun) do
    case :global.trans({{__MODULE__, Path.expand(path)}, self()}, fun) do
      :aborted -> {:error, :configuration_history_lock_unavailable}
      result -> result
    end
  end

  defp safe_directory(path) do
    case File.lstat(directory(path)) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _} -> {:error, :unsafe_history_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_directory(path) do
    case File.mkdir(directory(path)) do
      :ok ->
        File.chmod(directory(path), 0o700)

      {:error, :eexist} ->
        with :ok <- safe_directory(path), do: File.chmod(directory(path), 0o700)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_records(path) do
    case safe_directory(path) do
      {:error, :enoent} ->
        {:ok, []}

      :ok ->
        with {:ok, names} <- File.ls(directory(path)) do
          records =
            Enum.flat_map(names, fn name ->
              id = Path.rootname(name, ".json")

              if name == id <> ".json" and Regex.match?(@id_pattern, id) do
                case read_record(path, id) do
                  {:ok, record} -> [record]
                  _corrupt_or_removed -> []
                end
              else
                []
              end
            end)

          {:ok, Enum.sort_by(records, &{&1.saved_at, &1.id}, :desc)}
        end

      error ->
        error
    end
  end

  defp metadata_result({:ok, records}), do: {:ok, Enum.map(records, &Map.delete(&1, :source))}
  defp metadata_result(error), do: error

  defp read_record(path, id) do
    file = Path.join(directory(path), id <> ".json")

    with {:ok, %{type: :regular}} <- File.lstat(file),
         {:ok, json} <- File.read(file),
         {:ok,
          %{
            "version" => 1,
            "id" => ^id,
            "source_base64" => encoded,
            "saved_at" => saved,
            "activated_at" => activated,
            "valid" => valid
          }} <- Jason.decode(json),
         true <- is_binary(encoded) and is_boolean(valid),
         {:ok, source} <- Base.decode64(encoded),
         true <- digest(source) == id,
         {:ok, _, _} <- DateTime.from_iso8601(saved),
         true <- is_nil(activated) or match?({:ok, _, _}, DateTime.from_iso8601(activated)) do
      {:ok, %{id: id, source: source, saved_at: saved, activated_at: activated, valid?: valid}}
    else
      {:error, :enoent} -> {:error, :invalid_revision}
      _ -> {:error, :invalid_revision}
    end
  rescue
    _ -> {:error, :invalid_revision}
  end

  defp prune(path, records) do
    active =
      records |> Enum.filter(& &1.activated_at) |> Enum.max_by(& &1.activated_at, fn -> nil end)

    keep = Enum.take(records, @limit)

    keep =
      if active && not Enum.any?(keep, &(&1.id == active.id)),
        do: Enum.take(keep, @limit - 1) ++ [active],
        else: keep

    ids = MapSet.new(keep, & &1.id)

    Enum.reduce_while(records, :ok, fn record, :ok ->
      if MapSet.member?(ids, record.id) do
        {:cont, :ok}
      else
        case File.rm(Path.join(directory(path), record.id <> ".json")) do
          :ok -> {:cont, :ok}
          {:error, :enoent} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp atomic_record(path, id, json) do
    file = Path.join(directory(path), id <> ".json")
    temp = file <> ".#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}.tmp"

    try do
      with :ok <- File.write(temp, json, [:exclusive]),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.rename(temp, file),
           do: :ok
    after
      File.rm(temp)
    end
  end
end
