defmodule Exiron.Hub do
  @moduledoc false

  use GenServer

  require Logger

  alias Exiron.Hub.{
    Boot,
    ClientOperations,
    ClientSessions,
    Effect,
    EffectRunner,
    EventLog,
    IncomingMessages,
    Message,
    PollerRegistry,
    ProcessEvents,
    ReloadManager,
    State,
    StatusPublisher,
    TelegramEvents,
    Transition
  }

  alias Exiron.Hub.Telegram
  alias Exiron.Secret

  @version_file Path.expand("../../../VERSION", __DIR__)
  @external_resource @version_file
  @version @version_file |> File.read!() |> String.trim()
  @reload_actions [:reload_routes, :reload_bots, :reload_configuration]

  @doc false
  def server_version, do: @version

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, Application.get_env(:exiron, :hub, []), name: __MODULE__)
  end

  def subscribe_status do
    StatusPublisher.subscribe()
  end

  def subscribe_traces, do: Phoenix.PubSub.subscribe(Exiron.PubSub, "hub:traces")

  def request_trace_snapshot, do: GenServer.call(__MODULE__, :request_trace_snapshot)
  def hook_statuses, do: GenServer.call(__MODULE__, :hook_statuses)

  def socket_contact(hook, client_id, pid),
    do: GenServer.cast(__MODULE__, {:socket_contact, hook, client_id, pid})

  def request_traces, do: GenServer.call(__MODULE__, :request_traces)
  def request_trace(id), do: GenServer.call(__MODULE__, {:request_trace, id})

  def cancel_from_monitor(id),
    do: GenServer.call(__MODULE__, {:cancel_from_monitor, id}, :infinity)

  @doc "Pause new work while existing requests and sends finish. Timeout leaves intake paused."
  def start_drain(opts \\ []), do: GenServer.call(__MODULE__, {:start_drain, opts})
  def drain_status, do: GenServer.call(__MODULE__, :drain_status)
  def resume_intake, do: GenServer.call(__MODULE__, :resume_intake)
  def accepting_intake?, do: GenServer.call(__MODULE__, :accepting_intake)

  def readiness, do: GenServer.call(__MODULE__, :readiness, 1000)

  def status, do: GenServer.call(__MODULE__, :status)

  def metrics_snapshot, do: GenServer.call(__MODULE__, :metrics_snapshot, 1000)

  # Administrative comparison only. Never include source digests in public status.
  def configuration_status(source),
    do: GenServer.call(__MODULE__, {:configuration_status, :crypto.hash(:sha256, source)})

  def subscribe_configuration, do: Phoenix.PubSub.subscribe(Exiron.PubSub, "hub:configuration")

  def status_for_token(token),
    do: GenServer.call(__MODULE__, {:status_for_token, Secret.new(token)})

  def manual_targets, do: GenServer.call(__MODULE__, :manual_targets)
  def preview_manual(params), do: GenServer.call(__MODULE__, {:preview_manual, params})
  def send_manual(draft), do: send_call({:send_manual, draft})

  def telegram_bots, do: GenServer.call(__MODULE__, :telegram_bots)

  def telegram_polled(token, result) do
    GenServer.cast(
      __MODULE__,
      {:telegram_polled, Secret.new(token), self(), result, DateTime.utc_now()}
    )
  end

  def telegram_membership_changed(event) do
    event = Map.update(event, :bot_token, nil, &Secret.new/1)
    GenServer.call(__MODULE__, {:telegram_membership_changed, event}, :infinity)
  end

  def configure(router, telegram \\ nil),
    do: GenServer.call(__MODULE__, {:configure, router, telegram})

  def reload_routes, do: GenServer.call(__MODULE__, :reload_routes)

  def reload_bots, do: GenServer.call(__MODULE__, :reload_bots)

  def reload_configuration, do: GenServer.call(__MODULE__, :reload_configuration)

  def authenticate(token), do: GenServer.call(__MODULE__, {:authenticate, Secret.new(token)})

  def poll(token, opts \\ []) do
    opts = Keyword.put_new(opts, :client_id, "default")
    GenServer.call(__MODULE__, {:poll, Secret.new(token), opts})
  end

  def poll_delivery(token, opts \\ []) do
    opts = Keyword.put_new(opts, :client_id, "default")
    GenServer.call(__MODULE__, {:poll_delivery, Secret.new(token), opts})
  end

  def connect_socket(token, opts) do
    GenServer.call(__MODULE__, {:connect_socket, Secret.new(token), opts})
  end

  def disconnect_socket(hook, client_id, pid) do
    GenServer.call(__MODULE__, {:disconnect_socket, hook, client_id, pid})
  end

  def complete_socket_delivery(hook, client_id, pid, delivery_ref) do
    GenServer.cast(
      __MODULE__,
      {:complete_socket_delivery, hook, client_id, pid, delivery_ref}
    )
  end

  def delivery_diagnostics(token, id),
    do: GenServer.call(__MODULE__, {:delivery_diagnostics, Secret.new(token), id})

  def retire_client(token, client_id, delivery_id),
    do: GenServer.call(__MODULE__, {:retire_client, Secret.new(token), client_id, delivery_id})

  def renew_lease(token, client_id, batch),
    do: GenServer.call(__MODULE__, {:renew_lease, Secret.new(token), client_id, batch})

  def client_runtime_report(token, payload),
    do: GenServer.call(__MODULE__, {:client_runtime_report, Secret.new(token), payload})

  def handler_report(token, payload),
    do: GenServer.call(__MODULE__, {:handler_report, Secret.new(token), payload})

  def request_state(token, id),
    do: GenServer.call(__MODULE__, {:request_state, Secret.new(token), id})

  def cancel(token, request_id),
    do: GenServer.call(__MODULE__, {:cancel, Secret.new(token), request_id}, :infinity)

  def respond(token, request_id, datatype, data, opts \\ []),
    do: send_call({:respond, Secret.new(token), request_id, datatype, data, opts})

  def action(token, request_id, action \\ "typing", opts \\ []),
    do: send_call({:action, Secret.new(token), request_id, action, opts})

  def edit(token, request_id, datatype, data, opts \\ []),
    do: send_call({:edit, Secret.new(token), request_id, datatype, data, opts})

  def push(token, datatype, data, chat_id \\ nil, opts \\ []),
    do: send_call({:push, Secret.new(token), datatype, data, chat_id, opts})

  def incoming_service_message(message),
    do: GenServer.call(__MODULE__, {:incoming_service_message, message}, :infinity)

  def incoming_callback(token, query),
    do:
      GenServer.call(
        __MODULE__,
        {:incoming_callback, Secret.new(token), Exiron.Hub.Callbacks.sanitize(query)},
        1000
      )

  @impl true
  def init(opts) do
    :ok = EventLog.clear_media(%{})

    if Keyword.get(opts, :enabled, true) do
      case Boot.boot(opts) do
        {:ok, attrs} ->
          {:ok, StatusPublisher.initialize(State.new(attrs))}

        {:error, reason} ->
          Logger.error("Exiron disabled after boot failure: #{inspect(reason)}")
          {:ok, StatusPublisher.initialize(State.new(boot_failed?: true))}
      end
    else
      {:ok, StatusPublisher.initialize(State.new())}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, StatusPublisher.snapshot(state), state}
  end

  def handle_call(:readiness, _from, state) do
    reason =
      cond do
        state.boot_failed? -> :boot_failed
        not state.enabled? -> :disabled
        is_nil(state.router) or is_nil(state.telegram) -> :not_initialized
        state.drain.active? -> :draining
        true -> :initialized
      end

    {:reply, %{ready: reason == :initialized, reason: reason}, state}
  end

  def handle_call({:start_drain, opts}, _from, state),
    do: state |> Exiron.Hub.Drain.start(opts) |> reply_transition()

  def handle_call(:drain_status, _from, state),
    do: {:reply, Exiron.Hub.Drain.snapshot(state), state}

  def handle_call(:resume_intake, _from, state),
    do: state |> Exiron.Hub.Drain.resume() |> reply_transition()

  def handle_call(:accepting_intake, _from, state),
    do: {:reply, Exiron.Hub.Drain.admit(state) == :ok, state}

  def handle_call(:hook_statuses, _from, %{enabled?: true} = state),
    do: {:reply, Exiron.Hub.QueueState.hook_snapshots(state), state}

  def handle_call(:hook_statuses, _from, state), do: {:reply, [], state}

  def handle_call(:request_traces, _from, state),
    do: {:reply, Exiron.Hub.RequestTrace.list(state), state}

  def handle_call(:request_trace_snapshot, _from, state),
    do: {:reply, Exiron.Hub.RequestTrace.list(state, details: true), state}

  def handle_call({:request_trace, id}, _from, state),
    do: {:reply, Exiron.Hub.RequestTrace.fetch(state, id), state}

  def handle_call(:metrics_snapshot, _from, state) do
    hooks = if state.enabled?, do: Exiron.Hub.QueueState.hook_snapshots(state), else: []

    hooks =
      Enum.map(hooks, fn hook ->
        {_count, bytes} = Exiron.Hub.Queue.usage(state, hook.name)

        Map.merge(hook, %{
          buffered_bytes: bytes,
          buffered_bytes_limit: state.settings.max_queue_bytes_per_hook
        })
      end)

    {:reply,
     %{
       enabled: state.enabled?,
       hooks: hooks,
       pending: map_size(state.delivery.pending),
       pending_limit: state.settings.max_pending,
       buffer_capacity: Exiron.Hub.BufferBudget.snapshot(state),
       send_capacity: Exiron.Hub.SendBudget.snapshot(state),
       telegram_suppression:
         Exiron.Hub.Telegram.SendCoordinator.snapshot() |> Map.delete(:records),
       sends: map_size(state.delivery.sends),
       sends_limit: state.settings.max_in_flight_sends
     }, state}
  end

  def handle_call({:configuration_status, digest}, _from, state) do
    status =
      cond do
        not state.enabled? and not state.boot_failed? -> :disabled
        state.enabled? and state.configuration_digest == digest -> :active
        state.configuration_reload_failed? or state.boot_failed? -> :failed
        is_nil(state.configuration_digest) -> :unverified
        true -> :pending
      end

    {:reply, %{status: status, activated_at: state.configuration_activated_at}, state}
  end

  def handle_call({:status_for_token, token}, _from, state) do
    state
    |> ClientOperations.status(token, @version)
    |> reply_transition()
  end

  def handle_call(:manual_targets, _from, state),
    do: {:reply, Exiron.Hub.ManualMessages.targets(state), state}

  def handle_call({:preview_manual, params}, _from, state),
    do: {:reply, Exiron.Hub.ManualMessages.preview(state, params), state}

  def handle_call({:send_manual, draft}, from, state),
    do: state |> Exiron.Hub.ManualMessages.send(from, draft) |> reply_transition()

  def handle_call(:telegram_bots, _from, %State{telegram: %Telegram{} = telegram} = state) do
    {:reply, Telegram.bot_snapshots(telegram), state}
  end

  def handle_call(:telegram_bots, _from, state) do
    {:reply, [], state}
  end

  def handle_call({:configure, router, telegram}, _from, old_state) do
    old_state = ClientSessions.release_resources(old_state)
    :ok = Exiron.Hub.Telegram.SendCoordinator.clear_suppression()
    PollerRegistry.clear_monitors(old_state)
    :ok = EventLog.clear_media(old_state)
    state = State.new(Boot.configure_attrs(router, telegram))
    configuration_changed()

    Transition.new(state, reply: :ok, effects: [Effect.broadcast_status()])
    |> reply_transition()
  end

  def handle_call(
        :reload_configuration,
        _from,
        %State{enabled?: false, boot_failed?: true} = state
      ) do
    case Boot.boot(Application.get_env(:exiron, :hub, [])) do
      {:ok, attrs} ->
        :ok = EventLog.clear_media(state)
        state = State.new(attrs)
        configuration_changed()

        Transition.new(state, reply: :ok, effects: [Effect.broadcast_status()])
        |> reply_transition()

      {:error, reason} ->
        Logger.error("Exiron remains disabled after reload failure: #{inspect(reason)}")
        configuration_changed()
        {:reply, {:error, reason}, %{state | configuration_reload_failed?: true}}
    end
  end

  def handle_call(action, _from, %State{enabled?: false} = state)
      when action in @reload_actions do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call(action, _from, state) when action in @reload_actions do
    opts = Application.get_env(:exiron, :hub, [])

    with {:ok, state} <- ReloadManager.reload(state, action, opts) do
      configuration_changed()

      Transition.new(state, reply: :ok, effects: [Effect.broadcast_status()])
      |> reply_transition()
    else
      error ->
        configuration_changed()

        state =
          if action == :reload_configuration,
            do: %{state | configuration_reload_failed?: true},
            else: state

        {:reply, error, state}
    end
  end

  def handle_call({:authenticate, token}, _from, state) do
    state
    |> ClientOperations.authenticate(token, @version)
    |> reply_transition()
  end

  def handle_call({:poll, token, opts}, _from, state) do
    state
    |> ClientOperations.poll(token, opts)
    |> reply_transition()
  end

  def handle_call({:poll_delivery, token, opts}, _from, state) do
    state
    |> ClientOperations.poll_delivery(token, opts)
    |> reply_transition()
  end

  def handle_call({:connect_socket, token, opts}, _from, state) do
    state
    |> ClientOperations.connect_socket(token, opts, @version)
    |> reply_transition()
  end

  def handle_call({:disconnect_socket, hook, client_id, pid}, _from, state) do
    state
    |> ClientOperations.disconnect_socket(hook, client_id, pid)
    |> reply_transition()
  end

  def handle_call({:delivery_diagnostics, token, id}, _from, state),
    do: state |> ClientOperations.delivery_diagnostics(token, id) |> reply_transition()

  def handle_call({:retire_client, token, client_id, delivery_id}, _from, state),
    do: state |> ClientOperations.retire(token, client_id, delivery_id) |> reply_transition()

  def handle_call({:renew_lease, token, client_id, batch}, _from, state),
    do: state |> ClientOperations.renew_lease(token, client_id, batch) |> reply_transition()

  def handle_call({:client_runtime_report, token, payload}, _from, state),
    do: state |> ClientOperations.client_runtime_report(token, payload) |> reply_transition()

  def handle_call({:handler_report, token, payload}, _from, state),
    do: state |> ClientOperations.handler_report(token, payload) |> reply_transition()

  def handle_call({:request_state, token, id}, _from, state),
    do: state |> ClientOperations.request_state(token, id) |> reply_transition()

  def handle_call({:cancel, token, id}, _from, state),
    do: state |> ClientOperations.cancel(token, id) |> reply_transition()

  def handle_call({:cancel_from_monitor, id}, _from, state),
    do: state |> Exiron.Hub.RequestCancellation.cancel_from_monitor(id) |> reply_transition()

  def handle_call({:send_attempt, ref, phase}, {pid, _}, state) do
    {result, state} = Exiron.Hub.SendTasks.attempt_progress(state, ref, pid, phase)
    {:reply, result, state}
  end

  def handle_call({:respond, token, request_id, datatype, data, opts}, from, state) do
    state
    |> ClientOperations.respond(from, token, request_id, datatype, data, opts)
    |> reply_transition(from)
  end

  def handle_call({:action, token, request_id, action, opts}, from, state),
    do:
      state
      |> ClientOperations.action(from, token, request_id, action, opts)
      |> reply_transition()

  def handle_call({:edit, token, request_id, datatype, data, opts}, from, state),
    do:
      state
      |> ClientOperations.edit(from, token, request_id, datatype, data, opts)
      |> reply_transition()

  def handle_call({:push, token, datatype, data, chat_id, opts}, from, state) do
    state
    |> ClientOperations.push(from, token, datatype, data, chat_id, opts)
    |> reply_transition(from)
  end

  # Gate admission in the Hub as well as the poller: a long poll may finish
  # after drain begins. Retry leaves that update unacknowledged at Telegram.
  def handle_call(
        {:incoming_callback, token, query},
        _from,
        %{drain: %{active?: true}} = state
      ) do
    token = Secret.reveal(token)

    if Exiron.Hub.RequestInteraction.control?(state, token, query),
      do: state |> Exiron.Hub.Callbacks.handle(token, query) |> reply_transition(),
      else: {:reply, {:retry, :draining}, state}
  end

  def handle_call(
        {:incoming_service_message, %Message{}},
        _from,
        %{drain: %{active?: true}} = state
      ),
      do: {:reply, {:retry, :draining}, state}

  def handle_call({:incoming_callback, token, query}, _from, state) do
    state |> Exiron.Hub.Callbacks.handle(Secret.reveal(token), query) |> reply_transition()
  end

  def handle_call({:incoming_service_message, %Message{} = message}, _from, state) do
    state
    |> IncomingMessages.handle(message)
    |> reply_transition()
  end

  def handle_call({:telegram_membership_changed, event}, _from, state) do
    state
    |> TelegramEvents.membership_changed(event)
    |> reply_transition()
  end

  @impl true
  def handle_cast({:telegram_polled, token, pid, :started, at}, state) do
    state
    |> TelegramEvents.poller_started(token, pid, at)
    |> noreply_transition()
  end

  def handle_cast({:telegram_polled, token, pid, {:stopped, _reason}, _at}, state) do
    state
    |> TelegramEvents.poller_stopped(token, pid)
    |> noreply_transition()
  end

  def handle_cast({:socket_contact, hook, client_id, pid}, state) do
    {:noreply, Exiron.Hub.ClientPresence.socket_contact(state, hook, client_id, pid, :ping)}
  end

  def handle_cast({:complete_socket_delivery, hook, client_id, pid, delivery_ref}, state) do
    state
    |> ProcessEvents.complete_socket_delivery(hook, client_id, pid, delivery_ref)
    |> noreply_transition()
  end

  @impl true
  def handle_info({:drain_timeout, generation}, state),
    do: state |> Exiron.Hub.Drain.timeout(generation) |> noreply_transition()

  def handle_info({:expire_request, request_id}, state) do
    state
    |> ProcessEvents.expire_request(request_id)
    |> noreply_transition()
  end

  def handle_info({:expire_client, hook, client_id, lease}, state) do
    state
    |> ProcessEvents.expire_client(hook, client_id, lease)
    |> noreply_transition()
  end

  def handle_info({:trace_send, ref, request_id, kind, delay}, state)
      when kind in [:telegram_attempt, :telegram_rate_limited] do
    state =
      case Map.get(state.delivery.sends, ref) do
        %{command: %{request_id: ^request_id}} ->
          Exiron.Hub.RequestTrace.record(state, request_id, kind,
            detail: if(is_integer(delay), do: "Retry delay: #{delay} ms", else: nil)
          )

        _ ->
          state
      end

    state |> Transition.new(effects: [Effect.broadcast_status()]) |> noreply_transition()
  end

  def handle_info(:telegram_suppression_changed, state) do
    state |> Transition.new(effects: [Effect.broadcast_status()]) |> noreply_transition()
  end

  def handle_info({:send_complete, ref, result}, state) do
    state |> ProcessEvents.send_complete(ref, result) |> noreply_transition()
  end

  def handle_info({:send_timeout, ref}, state) do
    state |> ProcessEvents.send_timeout(ref) |> noreply_transition()
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    state
    |> ProcessEvents.down(monitor, pid, reason)
    |> noreply_transition()
  end

  def handle_info({:bot_identity_lookup_complete, generation, token, result}, state) do
    TelegramEvents.identity_lookup_complete(state, generation, token, result)
    |> noreply_transition()
  end

  def handle_info({:retry_bot_identity_lookup, generation, token}, state) do
    state
    |> TelegramEvents.retry_identity_lookup(generation, token)
    |> noreply_transition()
  end

  def handle_info({:bot_membership_lookup_complete, generation, token, chat_id, result}, state) do
    TelegramEvents.membership_lookup_complete(state, generation, token, chat_id, result)
    |> noreply_transition()
  end

  def handle_info({:retry_bot_membership_lookups, generation}, state) do
    state
    |> TelegramEvents.retry_membership_lookups(generation)
    |> noreply_transition()
  end

  @impl true
  def format_status(status) do
    Exiron.OTPStatus.redact(status, &status_state/1)
  end

  defp status_state(%State{} = state) do
    %{
      enabled?: state.enabled?,
      telegram_pollers_enabled?: state.telegram_pollers_enabled?,
      telegram_pollers: map_size(state.telegram_pollers),
      queues: map_size(state.delivery.queues),
      clients: map_size(state.delivery.clients),
      pending: map_size(state.delivery.pending),
      sends: map_size(state.delivery.sends),
      events: length(state.activity.events),
      client_events: length(state.activity.client_events)
    }
  end

  defp status_state(_state), do: :redacted

  defp send_call(request), do: GenServer.call(__MODULE__, request, :infinity)

  defp configuration_changed,
    do: Phoenix.PubSub.broadcast(Exiron.PubSub, "hub:configuration", :configuration_changed)

  defp reply_transition(transition, from \\ nil)

  defp reply_transition(%Transition{} = transition, from) do
    {state, reply} = EffectRunner.run(transition)

    {state, reply} =
      if from && reply != nil,
        do: Exiron.Hub.Idempotency.finish(state, from, reply),
        else: {state, reply}

    case reply do
      nil -> {:noreply, state}
      reply -> {:reply, reply, state}
    end
  end

  defp noreply_transition(%Transition{} = transition) do
    {state, _reply} = EffectRunner.run(transition)
    {:noreply, state}
  end
end
