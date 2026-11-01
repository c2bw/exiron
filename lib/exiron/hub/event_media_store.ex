defmodule Exiron.Hub.EventMediaStore do
  @moduledoc false

  use GenServer

  @default_max_bytes 64 * 1024 * 1024

  @type scope :: :dashboard | {:hook, String.t()} | nil
  @type media :: %{mime_type: String.t(), bytes: binary()}

  defstruct entries: %{}, order: :queue.new(), bytes: 0, max_bytes: @default_max_bytes

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(bytes, mime_type, scope)
      when is_binary(bytes) and is_binary(mime_type) do
    put(__MODULE__, bytes, mime_type, scope)
  end

  def put(store, bytes, mime_type) when (is_atom(store) or is_pid(store)) and is_binary(bytes) do
    put(store, bytes, mime_type, nil)
  end

  def put(store, bytes, mime_type, scope)
      when (is_atom(store) or is_pid(store)) and is_binary(bytes) and is_binary(mime_type) do
    call(store, {:put, bytes, mime_type, scope})
  end

  def fetch(id, scope) when is_binary(id) do
    fetch(__MODULE__, id, scope)
  end

  def fetch(store, id) when (is_atom(store) or is_pid(store)) and is_binary(id) do
    fetch(store, id, :dashboard)
  end

  def fetch(store, id, scope) when (is_atom(store) or is_pid(store)) and is_binary(id) do
    call(store, {:fetch, id, scope})
  end

  def delete(id) when is_binary(id), do: delete(__MODULE__, id)

  def delete(store, id) when (is_atom(store) or is_pid(store)) and is_binary(id) do
    call(store, {:delete, id})
  end

  def clear(store \\ __MODULE__) do
    call(store, :clear)
  end

  @impl true
  def init(opts) do
    max_bytes =
      opts
      |> Keyword.get_lazy(:max_bytes, &configured_max_bytes/0)
      |> normalize_max_bytes()

    {:ok, %__MODULE__{max_bytes: max_bytes}}
  end

  @impl true
  def handle_call({:put, bytes, mime_type, scope}, _from, state) do
    size = byte_size(bytes)

    if size == 0 or size > state.max_bytes do
      {:reply, {:error, :too_large}, state}
    else
      id = new_id(state.entries)
      {entries, order, bytes_used} = evict_for(state, size)

      entry = %{mime_type: mime_type, bytes: bytes, scope: scope, size: size}

      state = %{
        state
        | entries: Map.put(entries, id, entry),
          order: :queue.in(id, order),
          bytes: bytes_used + size
      }

      {:reply, {:ok, id}, state}
    end
  end

  @impl true
  def handle_call({:fetch, id, scope}, _from, state) do
    reply =
      case Map.get(state.entries, id) do
        %{scope: entry_scope, mime_type: mime_type, bytes: bytes}
        when scope == :dashboard or entry_scope == scope ->
          {:ok, %{mime_type: mime_type, bytes: bytes}}

        _missing_or_forbidden ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, id}, _from, state) do
    case Map.pop(state.entries, id) do
      {nil, _entries} ->
        {:reply, :ok, state}

      {%{size: size}, entries} ->
        order = state.order |> :queue.to_list() |> Enum.reject(&(&1 == id)) |> :queue.from_list()
        {:reply, :ok, %{state | entries: entries, order: order, bytes: state.bytes - size}}
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: %{}, order: :queue.new(), bytes: 0}}
  end

  @impl true
  def format_status(status) do
    Exiron.OTPStatus.redact(status, &status_state/1)
  end

  defp call(store, request) do
    case store do
      pid when is_pid(pid) ->
        GenServer.call(pid, request)

      name when is_atom(name) ->
        if Process.whereis(name) do
          GenServer.call(name, request)
        else
          {:error, :unavailable}
        end
    end
  end

  defp evict_for(%{entries: entries, order: order, bytes: bytes, max_bytes: max_bytes}, size) do
    if bytes + size <= max_bytes do
      {entries, order, bytes}
    else
      evict_oldest(entries, order, bytes, max_bytes - size)
    end
  end

  defp evict_oldest(entries, order, bytes, target_bytes) when bytes <= target_bytes,
    do: {entries, order, bytes}

  defp evict_oldest(entries, order, bytes, target_bytes) do
    case :queue.out(order) do
      {{:value, id}, order} ->
        case Map.pop(entries, id) do
          {nil, entries} ->
            evict_oldest(entries, order, bytes, target_bytes)

          {%{size: size}, entries} ->
            evict_oldest(entries, order, bytes - size, target_bytes)
        end

      {:empty, order} ->
        {entries, order, bytes}
    end
  end

  defp new_id(entries) do
    id = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    if Map.has_key?(entries, id), do: new_id(entries), else: id
  end

  defp configured_max_bytes do
    :exiron
    |> Application.get_env(:hub, [])
    |> Keyword.get(:max_event_image_history_bytes, @default_max_bytes)
  end

  defp normalize_max_bytes(value) when is_integer(value) and value >= 0, do: value
  defp normalize_max_bytes(_value), do: @default_max_bytes

  defp status_state(%__MODULE__{} = state) do
    %{
      entries: map_size(state.entries),
      bytes: state.bytes,
      max_bytes: state.max_bytes
    }
  end

  defp status_state(_state), do: :redacted
end
