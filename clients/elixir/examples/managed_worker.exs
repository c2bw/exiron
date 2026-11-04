defmodule ExironExampleWorker do
  @moduledoc """
  Interactive reference worker. Load with:

      iex -S mix run examples/managed_worker.exs

  Then call start/0. See docs/managed-worker-examples.md for setup and recovery.
  Loading this file alone never connects or sends messages.
  """
  require Logger
  alias ExironClient.{Poller, Quarantine, HandlerDeadline, Feedback, Protocol}
  @supervisor __MODULE__.Supervisor
  @store __MODULE__.Quarantine
  @state __MODULE__.State

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  def start(opts \\ []), do: start_link(opts)

  def start_link(opts) do
    settings = settings(opts)

    children = [
      {Quarantine, name: @store, max_messages: 100, max_bytes: 8 * 1024 * 1024},
      %{
        id: @state,
        start:
          {Agent, :start_link,
           [
             fn -> Map.merge(settings, %{supervisor: nil, store: nil, poller: nil}) end,
             [name: @state]
           ]}
      }
    ]

    with {:ok, supervisor} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: @supervisor) do
      Agent.update(@state, &%{&1 | supervisor: supervisor, store: Process.whereis(@store)})

      case restart() do
        {:ok, _poller} ->
          {:ok, supervisor}

        error ->
          Supervisor.stop(supervisor)
          error
      end
    end
  end

  def status do
    with {:ok, state} <- state() do
      %{worker: poller_status(state.poller), quarantine: Quarantine.stats(state.store)}
    end
  end

  def quarantine do
    with {:ok, state} <- state(), do: Quarantine.entries(state.store)
  end

  @doc "Invoke an explicit recovery callback. Only :ok removes the retained entry."
  def recover(id, callback) when is_function(callback, 1) do
    with {:ok, state} <- state(), do: Quarantine.recover(state.store, id, callback)
  end

  @doc "Send an operator-chosen final plain-text reply, never replay the original handler."
  def recover_text(id, text) when is_binary(text) do
    with {:ok, state} <- state() do
      if String.trim(text) == "" do
        {:error, :empty_replacement}
      else
        Quarantine.recover(state.store, id, fn original ->
          if original.msgtype == "request" and is_binary(original.req_id),
            do: reply(state.client, original, text),
            else: {:error, :no_routed_request}
        end)
      end
    end
  end

  @doc "Explicitly resolve an entry handled externally. This deliberately sends nothing."
  def resolve(id), do: recover(id, fn _original -> :ok end)

  @doc "Drain the poller while retaining its separately supervised quarantine and client."
  def drain do
    with {:ok, state} <- state() do
      case poller_status(state.poller) do
        {:error, :not_running} -> :ok
        {:ok, _} -> Poller.drain(state.poller, 30_000)
      end
    end
  end

  @doc "Restart only after the previous managed process has actually stopped."
  def restart do
    with {:ok, state} <- state() do
      case poller_status(state.poller) do
        {:ok, _} ->
          {:error, :already_running}

        {:error, :not_running} ->
          opts = [
            client: state.client,
            transport: state.transport,
            handler: &handle(state.client, state.reply_mode, state.feedback, &1),
            handler_concurrency: 2,
            handler_order_by_chat: true,
            handler_timeout_ms: 30_000,
            graceful_shutdown: true,
            runtime_reporting: true,
            cooperative_cancellation: true,
            report_handler_failures: true,
            # Never replay a send or partial stream automatically.
            handler_max_attempts: 1,
            handler_failure_policy: :quarantine,
            quarantine: state.store,
            on_quarantined: state.on_quarantined,
            on_disconnect: fn reason ->
              Logger.info(
                "managed worker disconnected: #{inspect(ExironClient.Error.summary(reason))}"
              )
            end
          ]

          case start_poller(state, opts) do
            {:ok, pid} = result ->
              Agent.update(@state, &%{&1 | poller: pid})
              result

            error ->
              error
          end
      end
    end
  end

  @doc "Drain, then stop the example supervisor. Remaining in-memory entries are lost."
  def shutdown do
    with {:ok, state} <- state() do
      result = drain()

      case Quarantine.stats(state.store) do
        {:ok, %{count: count}} ->
          Logger.info("example shutting down with #{count} in-memory quarantine entries")

        _ ->
          :ok
      end

      Supervisor.stop(state.supervisor)
      result
    end
  end

  defp start_poller(state, opts) do
    with :ok <- feedback_capabilities(state),
         do: Supervisor.start_child(state.supervisor, {Poller, opts})
  end

  defp feedback_capabilities(%{feedback: false}), do: :ok

  defp feedback_capabilities(state) do
    with {:ok, protocol} <- ExironClient.capabilities(state.client) do
      if Protocol.supports?(protocol, "inline_keyboards") and
           Protocol.supports?(protocol, "callback_queries"),
         do: :ok,
         else: {:error, :feedback_not_supported}
    end
  end

  defp handle(_client, _mode, _feedback, %{msgtype: type}) when type != "request", do: :ok

  defp handle(client, _mode, true, %{datatype: "callback"} = message) do
    case Feedback.from_message(message) do
      {:ok, _rating} -> reply(client, message, "Thanks for the feedback.")
      :error -> {:error, :example_only_handles_text}
    end
  end

  defp handle(_client, _mode, _feedback, %{datatype: type}) when type != "text",
    do: {:error, :example_only_handles_text}

  defp handle(client, mode, feedback, message) do
    if List.last(String.split(message.data)) == "/worker-fail" do
      {:error, :example_failure_before_send}
    else
      prefix = if message.followup_req_id, do: "Follow-up received: ", else: "Received: "
      answer = prefix <> (message.data |> String.codepoints() |> Enum.take(1024) |> Enum.join())

      case mode do
        :one_shot ->
          reply(client, message, answer, feedback)

        :stream ->
          chunks =
            answer
            |> String.codepoints()
            |> Enum.chunk_every(128)
            |> Stream.map(fn part ->
              HandlerDeadline.wait(150)
              Enum.join(part)
            end)

          normalize(
            ExironClient.stream_text(
              client,
              message,
              chunks,
              [interval_ms: 300] ++ reply_options(feedback)
            )
          )
      end
    end
  end

  defp reply_options(false), do: [parse_mode: "plain"]

  defp reply_options(true) do
    {:ok, keyboard} = Feedback.keyboard()
    [parse_mode: "plain", inline_keyboard: keyboard]
  end

  defp reply(client, message, text, feedback \\ false),
    do: normalize(ExironClient.respond(client, message, "text", text, reply_options(feedback)))

  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, _} = error), do: error

  defp request_observer do
    case System.get_env("EXIRON_OBSERVE_REQUESTS", "false") do
      value when value in ["", "false"] -> nil
      "true" -> fn event -> Logger.info("api request: #{inspect(event)}") end
      _ -> raise ArgumentError, "EXIRON_OBSERVE_REQUESTS must be true or false"
    end
  end

  defp settings(opts) do
    client =
      Keyword.get_lazy(opts, :client, fn ->
        token = System.fetch_env!("EXIRON_HOOK_TOKEN")
        if String.trim(token) == "", do: raise(ArgumentError, "EXIRON_HOOK_TOKEN is required")

        client_opts = [
          on_request: request_observer(),
          base_url: System.get_env("EXIRON_BASE_URL", "http://localhost:4000"),
          token: token,
          req_options: [
            receive_timeout: 10_000,
            finch: [pool_timeout: 5000, conn_opts: [transport_opts: [timeout: 5000]]]
          ]
        ]

        id = System.get_env("EXIRON_CLIENT_ID")

        client_opts =
          if id in [nil, ""], do: client_opts, else: Keyword.put(client_opts, :client_id, id)

        ExironClient.new(client_opts)
      end)

    mode =
      Keyword.get_lazy(opts, :reply_mode, fn ->
        case System.get_env("EXIRON_REPLY_MODE", "one-shot") do
          "one-shot" -> :one_shot
          "stream" -> :stream
          _ -> raise ArgumentError, "EXIRON_REPLY_MODE must be one-shot or stream"
        end
      end)

    transport =
      Keyword.get_lazy(opts, :transport, fn ->
        case System.get_env("EXIRON_TRANSPORT", "websocket") do
          "websocket" -> :websocket
          "http" -> :http
          _ -> raise ArgumentError, "EXIRON_TRANSPORT must be http or websocket"
        end
      end)

    feedback =
      Keyword.get_lazy(opts, :feedback, fn ->
        case System.get_env("EXIRON_FEEDBACK", "false") do
          "false" -> false
          "true" -> true
          _ -> raise ArgumentError, "EXIRON_FEEDBACK must be true or false"
        end
      end)

    unless is_boolean(feedback), do: raise(ArgumentError, "feedback must be boolean")

    unless mode in [:one_shot, :stream] and transport in [:http, :websocket],
      do: raise(ArgumentError, "invalid example reply mode or transport")

    %{
      client: client,
      reply_mode: mode,
      feedback: feedback,
      transport: transport,
      on_quarantined:
        Keyword.get(opts, :on_quarantined, fn _entry ->
          Logger.warning("message quarantined; inspect ExironExampleWorker.quarantine()")
        end)
    }
  end

  defp state do
    case Process.whereis(@state) do
      nil -> {:error, :not_started}
      pid -> {:ok, Agent.get(pid, & &1)}
    end
  end

  defp poller_status(nil), do: {:error, :not_running}
  defp poller_status(pid), do: Poller.status(pid)
end
