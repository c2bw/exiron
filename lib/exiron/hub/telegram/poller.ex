defmodule Exiron.Hub.Telegram.Poller do
  @moduledoc false

  use GenServer

  require Logger

  alias Exiron.Telemetry
  alias Exiron.Hub.Telegram.AlbumBuffer
  alias Exiron.Hub.Telegram.PollerState
  alias Exiron.Hub.Telegram.Poller.UpdateProcessor
  alias Exiron.Secret

  @poll_timeout 25
  @retry_delay 1_000
  @empty_poll_delay 100
  @max_download_bytes 50 * 1024 * 1024

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [protect_token(opts)]},
      restart: :transient
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, protect_token(opts))
  end

  def put_bot_name(pid, token, bot_name) when is_pid(pid) and is_binary(token) do
    GenServer.cast(pid, {:put_bot_name, Secret.new(token), bot_name})
  end

  @impl true
  def init(opts) do
    state = %PollerState{
      token: opts |> Keyword.fetch!(:token) |> Secret.reveal(),
      bot_name: Keyword.get(opts, :bot_name),
      offset: nil,
      answer_callback:
        Keyword.get(opts, :answer_callback, &Exiron.Hub.Telegram.CallbackAnswer.answer/3),
      group_albums:
        Keyword.get(opts, :group_albums, Application.get_env(:exiron, :group_albums, false)),
      get_updates: Keyword.get(opts, :get_updates, &ExGram.get_updates/1),
      get_file: Keyword.get(opts, :get_file, &ExGram.get_file/2),
      http_get: Keyword.get(opts, :http_get, &Req.get/2),
      max_download_bytes: Keyword.get(opts, :max_download_bytes, @max_download_bytes),
      empty_poll_delay: Keyword.get(opts, :empty_poll_delay, @empty_poll_delay)
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state), do: poll(state)

  @impl true
  def handle_cast({:put_bot_name, token, bot_name}, state) do
    if Secret.reveal(token) == state.token do
      {:noreply, %{state | bot_name: bot_name}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll, state), do: poll(state)

  @impl true
  def terminate(reason, state) do
    Exiron.Hub.telegram_polled(state.token, {:stopped, reason})
    :ok
  end

  @impl true
  def format_status(status) do
    Exiron.OTPStatus.redact(status, &status_state/1)
  end

  defp poll(state) do
    if Exiron.Hub.accepting_intake?() do
      poll_active(state)
    else
      Process.send_after(self(), :poll, 1000)
      {:noreply, state}
    end
  end

  defp poll_active(state) do
    if AlbumBuffer.pending?(state) do
      case AlbumBuffer.collect(state, []) do
        {:ready, updates, state} -> process_updates(state, updates)
        {:buffered, state} -> poll_telegram(state)
      end
    else
      poll_telegram(state)
    end
  end

  defp poll_telegram(state) do
    Exiron.Hub.telegram_polled(state.token, :started)

    case get_updates(state) do
      {:ok, updates} ->
        state = UpdateProcessor.prioritize_callbacks(state, updates)

        case AlbumBuffer.collect(state, updates) do
          {:buffered, state} ->
            Process.send_after(self(), :poll, 100)
            {:noreply, state}

          {:ready, updates, state} ->
            process_updates(state, updates)
        end

      {:error, %ExGram.Error{code: 401} = reason} ->
        Logger.warning("Telegram polling stopped: #{inspect(reason)}")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Telegram polling failed: #{inspect(reason)}")
        Process.send_after(self(), :poll, @retry_delay)
        {:noreply, state}
    end
  end

  defp process_updates(state, updates) do
    case UpdateProcessor.process(state, updates) do
      {:ok, offset} ->
        schedule_next_poll(state, updates)

        {:noreply,
         %{
           state
           | offset: offset,
             processed_callbacks: MapSet.filter(state.processed_callbacks, &(&1 >= offset))
         }}

      {:retry, offset, reason} ->
        Logger.warning(
          "Telegram update processing failed; retrying update #{offset}: #{inspect(reason)}"
        )

        Process.send_after(self(), :poll, @retry_delay)

        {:noreply,
         %{
           state
           | offset: offset,
             processed_callbacks: MapSet.filter(state.processed_callbacks, &(&1 >= offset))
         }}
    end
  end

  defp get_updates(state) do
    started_at = System.monotonic_time()

    result =
      try do
        {:result,
         state.get_updates.(
           poll_options(state)
           |> Keyword.put(:timeout, if(AlbumBuffer.pending?(state), do: 0, else: @poll_timeout))
         )}
      catch
        kind, reason -> {:exception, kind, reason, __STACKTRACE__}
      end

    Telemetry.poll(System.monotonic_time() - started_at, poll_outcome(result))

    case result do
      {:result, value} -> value
      {:exception, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp poll_outcome({:result, {:ok, _updates}}), do: :ok
  defp poll_outcome({:result, {:error, _reason}}), do: :error
  defp poll_outcome({:result, _result}), do: :error
  defp poll_outcome({:exception, _kind, _reason, _stacktrace}), do: :exception

  defp poll_options(%{offset: nil} = state),
    do: [
      token: state.token,
      timeout: @poll_timeout,
      allowed_updates: ["message", "my_chat_member", "callback_query"]
    ]

  defp poll_options(state),
    do: [
      token: state.token,
      timeout: @poll_timeout,
      offset: state.offset,
      allowed_updates: ["message", "my_chat_member", "callback_query"]
    ]

  defp schedule_next_poll(state, []),
    do: Process.send_after(self(), :poll, state.empty_poll_delay)

  defp schedule_next_poll(_state, _updates), do: send(self(), :poll)

  defp status_state(%PollerState{} = state) do
    %{
      bot_name: state.bot_name,
      offset: state.offset,
      max_download_bytes: state.max_download_bytes,
      empty_poll_delay: state.empty_poll_delay
    }
  end

  defp status_state(_state), do: :redacted

  defp protect_token(opts) do
    case Keyword.fetch(opts, :token) do
      {:ok, token} -> Keyword.put(opts, :token, Secret.new(token))
      :error -> opts
    end
  end
end
