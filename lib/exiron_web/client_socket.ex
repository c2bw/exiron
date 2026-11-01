defmodule ExironWeb.ClientSocket do
  @behaviour WebSock

  alias Exiron.Hub
  alias Exiron.Protocol
  alias Exiron.Secret

  @impl true
  def init(%{client_id: client_id, listen: listen} = params) do
    credential = params |> credential() |> Secret.reveal()

    case Hub.connect_socket(credential,
           client_id: client_id,
           listen: listen,
           pid: self(),
           client_identity: Map.get(params, :client_identity)
         ) do
      {:ok, connected} ->
        state = %{
          hook: connected.hook,
          client_id: connected.client_id,
          delivery_ref: connected.delivery_ref
        }

        {:push, connected_frames(connected), state}

      {:error, reason} ->
        {:stop, :normal, {4009, Protocol.error_message(reason)}, error_frame(reason), %{}}
    end
  end

  @impl true
  def handle_in({payload, [opcode: :text]}, state) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "ping"}} ->
        Hub.socket_contact(state.hook, state.client_id, self())
        {:push, pong_frame(), state}

      {:ok, %{"type" => "ack", "delivery_id" => delivery_id}} ->
        acknowledge_delivery(delivery_id, state)

      _other ->
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:exiron_messages, delivery_ref, messages}, %{delivery_ref: nil} = state) do
    {:push, messages_frame(messages, delivery_ref), %{state | delivery_ref: delivery_ref}}
  end

  def handle_info({:exiron_socket_replaced, _pid}, state) do
    {:stop, :normal, {1000, "replaced"}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{hook: hook, client_id: client_id}) do
    Hub.disconnect_socket(hook, client_id, self())
  end

  def terminate(_reason, _state), do: :ok

  defp credential(%{credential: credential}), do: credential
  defp credential(%{token: token}), do: token

  @doc false
  def connected_frames(connected) do
    [
      text_frame(Protocol.connected_payload(connected)),
      messages_frame(connected.messages, connected.delivery_ref)
    ]
  end

  @doc false
  def messages_frame(messages, delivery_id),
    do:
      typed_frame(Protocol.websocket_server_frame_type(:messages), %{
        delivery_id: delivery_id,
        messages: messages
      })

  @doc false
  def pong_frame, do: typed_frame(Protocol.websocket_server_frame_type(:pong))

  @doc false
  def error_frame(reason), do: text_frame(Protocol.websocket_error_payload(reason))

  defp acknowledge_delivery(
         delivery_id,
         %{hook: hook, client_id: client_id, delivery_ref: delivery_id} = state
       )
       when is_binary(delivery_id) do
    Hub.complete_socket_delivery(hook, client_id, self(), delivery_id)
    {:ok, %{state | delivery_ref: nil}}
  end

  defp acknowledge_delivery(_delivery_id, state), do: {:ok, state}

  defp typed_frame(type, payload \\ %{}), do: text_frame(Map.put(payload, :type, type))
  defp text_frame(payload), do: {:text, Jason.encode!(payload)}
end
