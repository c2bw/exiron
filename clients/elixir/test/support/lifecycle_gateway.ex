defmodule ExironClient.LifecycleGateway do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(opts) do
    counters =
      for {key, _} <- opts.scenario["expect"],
          key != "outcome",
          into: %{},
          do: {key, if(key == "replies", do: [], else: 0)}

    {:ok, Map.merge(opts, %{observed: counters, available: true, stage: 0, cancelled: false})}
  end

  def add(pid, key), do: GenServer.call(pid, {:add, key})
  def observe(pid, key, value), do: GenServer.call(pid, {:observe, key, value})
  def observed(pid), do: GenServer.call(pid, :observed)
  def message(pid), do: GenServer.call(pid, :message)
  def ack(pid), do: GenServer.call(pid, :ack)
  def cancel(pid), do: GenServer.call(pid, :cancel)

  def adapter(pid) do
    fn req ->
      case GenServer.call(pid, {:request, req}) do
        {:ok, body} -> {req, Req.Response.json(body)}
        :drop -> {req, %Req.TransportError{reason: :closed}}
      end
    end
  end

  def handle_call({:add, key}, _, state), do: {:reply, :ok, increment(state, key)}

  def handle_call({:observe, key, value}, _, state),
    do: {:reply, :ok, put_in(state.observed[key], value)}

  def handle_call(:observed, _, state), do: {:reply, state.observed, state}
  def handle_call(:cancel, _, state), do: {:reply, :ok, %{state | cancelled: true}}
  def handle_call(:message, _, state), do: {:reply, delivery(state), state}

  def handle_call(:ack, _, state) do
    {result, state} = acknowledge(state)
    {:reply, result, state}
  end

  def handle_call({:request, req}, _, state) do
    case req.url.path do
      "/api/capabilities" ->
        {:reply, {:ok, ExironClient.FixtureHelpers.contract_json("capabilities_response.json")},
         state}

      "/api/requests" ->
        query = URI.decode_query(req.url.query || "")

        if query["delivery_ack"] do
          if query["delivery_ack"] != "batch", do: raise("acknowledged wrong HTTP delivery")
          {result, state} = acknowledge(state)
          response = if result == :drop, do: :drop, else: {:ok, %{requests: []}}
          {:reply, response, state}
        else
          body =
            case delivery(state) do
              nil -> %{requests: []}
              message -> %{delivery_id: "batch", requests: [message]}
            end

          {:reply, {:ok, body}, state}
        end

      "/api/client-lease" ->
        {:reply, {:ok, %{ok: true, lease_timeout_ms: 10000}}, state}

      "/api/request-state" ->
        id = URI.decode_query(req.url.query)["req_id"]

        {:reply,
         {:ok, %{req_id: id, state: if(state.cancelled, do: "cancelled", else: "active")}}, state}

      "/api/responses" ->
        payload = req.options[:json]
        partial? = payload[:final] == false

        reply = %{
          "request_id" => payload[:req_id],
          "text" => Base.decode64!(payload[:data]),
          "final" => not partial?
        }

        state = update_in(state.observed["replies"], &(&1 ++ [reply]))
        state = increment(state, if(partial?, do: "partial_replies", else: "final_replies"))
        if partial?, do: send(state.parent, :lifecycle_partial)
        {:reply, {:ok, %{ok: true}}, state}

      "/api/client-retire" ->
        if req.options[:json][:delivery_id] != "batch" or
             req.options[:json][:client_id] != "lifecycle" do
          raise "retired wrong delivery"
        end

        state = increment(state, "retirements")
        stage = state.stage + 1
        available = state.scenario["operation"] == "quarantine_recovery_restart" and stage == 1
        {:reply, {:ok, %{ok: true}}, %{state | stage: stage, available: available}}
    end
  end

  defp delivery(%{available: false}), do: nil

  defp delivery(state) do
    if state.stage == 0,
      do: state.catalog["message"],
      else: Map.put(state.catalog["message"], "req_id", "req-2")
  end

  defp acknowledge(state) do
    state = increment(state, "ack_attempts")

    if state.scenario["operation"] == "connection_loss_before_ack" and
         state.observed["ack_attempts"] == 1 do
      {:drop, state}
    else
      send(state.parent, :lifecycle_acknowledged)
      {:ok, %{increment(state, "ack_commits") | available: false}}
    end
  end

  defp increment(state, key), do: update_in(state.observed[key], &(&1 + 1))
end
