defmodule Exiron.Hub.ConfigurationService do
  @moduledoc false

  alias Exiron.Hub
  alias Exiron.Hub.RouteConfiguration
  alias Exiron.Hub.ConfigurationHistory
  alias Exiron.Hub.RouteConfiguration.ConflictError

  @default_file_mode 0o600
  @private_directory_mode 0o700
  @skip_source_check :skip_source_check
  @lock_namespace Exiron.Hub.RouteConfiguration

  @type reload_result :: :ok | {:error, term()}
  @type save_and_reload_result ::
          {:ok,
           %{
             configuration: RouteConfiguration.t(),
             reload: reload_result(),
             source: String.t(),
             history: {:ok, String.t()} | {:error, term()}
           }}
          | {:error, term()}

  @spec save(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def save(path, source, opts \\ []) do
    expected_source = Keyword.get(opts, :expected_source, @skip_source_check)

    with {:ok, _config} <- RouteConfiguration.load_source(path, source) do
      locked_write(path, source, expected_source)
    end
  end

  @spec save_and_reload(Path.t(), String.t(), keyword()) :: save_and_reload_result()
  def save_and_reload(path, source, opts \\ []) do
    with {:ok, configuration} <- RouteConfiguration.load_source(path, source),
         :ok <- save(path, source, opts) do
      # The pre-change checkpoint was mandatory. A post-save checkpoint is
      # best-effort: its failure must not misreport an already-written file.
      history = ConfigurationHistory.checkpoint(path, source, saved: true)
      Phoenix.PubSub.broadcast(Exiron.PubSub, "hub:configuration", :configuration_changed)
      reload_fun = Keyword.get(opts, :reload, &Hub.reload_configuration/0)
      reload = reload_safely(reload_fun)
      {:ok, %{configuration: configuration, reload: reload, source: source, history: history}}
    end
  end

  def current_source(path), do: read_source(path)

  def rollback(path, id, opts \\ []) do
    with {:ok, current} <- read_source(path),
         {:ok, source} <- ConfigurationHistory.fetch(path, id),
         {:ok, _configuration} <- RouteConfiguration.load_source(path, source) do
      save_and_reload(path, source, Keyword.put_new(opts, :expected_source, current))
    end
  end

  @doc false
  def activate_saved(path, expected_source, opts \\ []) do
    lock = {{@lock_namespace, Path.expand(path)}, self()}
    reload_fun = Keyword.get(opts, :reload, &Hub.reload_configuration/0)

    case :global.trans(lock, fn ->
           with :ok <- ensure_expected_source(path, expected_source),
                {:ok, _configuration} <- RouteConfiguration.load(path) do
             reload_safely(reload_fun)
           end
         end) do
      :aborted -> {:error, :configuration_write_lock_unavailable}
      result -> result
    end
  end

  defp reload_safely(reload_fun) do
    reload_fun.()
  catch
    :exit, _reason -> {:error, :activation_unconfirmed}
  end

  @spec error_message(term()) :: String.t()
  def error_message(reason) when is_binary(reason), do: reason

  def error_message({:configuration_history, _reason}),
    do:
      "Cannot preserve configuration history. Check the history directory permissions and disk space. The file was not changed."

  def error_message(:invalid_revision), do: "That configuration revision is missing or corrupted."

  def error_message(reason) when is_atom(reason),
    do: String.trim_leading(Atom.to_string(reason), "Elixir.")

  def error_message(reason),
    do: if(is_exception(reason), do: Exception.message(reason), else: inspect(reason))

  defp locked_write(path, source, expected_source) do
    lock = {{@lock_namespace, Path.expand(path)}, self()}

    case :global.trans(lock, fn ->
           with :ok <- ensure_expected_source(path, expected_source),
                {:ok, previous} <- read_source(path),
                :ok <- checkpoint_previous(path, previous) do
             write_atomic(path, source)
           end
         end) do
      :aborted -> {:error, :configuration_write_lock_unavailable}
      result -> result
    end
  end

  defp checkpoint_previous(path, source) do
    case ConfigurationHistory.checkpoint(path, source) do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, {:configuration_history, reason}}
    end
  end

  defp ensure_expected_source(_path, @skip_source_check), do: :ok

  defp ensure_expected_source(path, expected_source) when is_binary(expected_source) do
    case read_source(path) do
      {:ok, ^expected_source} -> :ok
      {:ok, _current_source} -> {:error, ConflictError.exception(path: path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_source(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, :enoent} -> {:ok, Exiron.Hub.Configuration.empty_source()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_atomic(path, source) do
    with {:ok, mode} <- target_mode(path),
         :ok <-
           with_private_staging_file(path, fn temp_path ->
             with :ok <- File.write(temp_path, source, [:exclusive]),
                  :ok <- File.chmod(temp_path, mode),
                  :ok <- File.rename(temp_path, path) do
               :ok
             end
           end) do
      :ok
    end
  end

  defp target_mode(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, Bitwise.band(stat.mode, 0o7777)}
      {:error, :enoent} -> {:ok, @default_file_mode}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_private_staging_file(path, write) do
    directory = temporary_directory(path)

    case File.mkdir(directory) do
      :ok ->
        temp_path = Path.join(directory, Path.basename(path))

        try do
          with :ok <- File.chmod(directory, @private_directory_mode) do
            write.(temp_path)
          end
        after
          remove_temporary_file(temp_path)
          File.rmdir(directory)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_temporary_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp temporary_directory(path) do
    dirname = Path.dirname(path)
    basename = Path.basename(path)
    unique = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    Path.join(dirname, ".#{basename}.#{unique}.tmp")
  end
end
