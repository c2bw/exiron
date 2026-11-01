defmodule Exiron.Hub.ClientSession do
  @moduledoc false

  @type t :: %__MODULE__{
          client_id: String.t() | nil,
          client_identity: %{sdk: String.t(), version: String.t()} | nil,
          runtime_ref: String.t() | nil,
          last_ack_ref: String.t() | nil,
          lease: term(),
          timer: reference() | nil,
          transport: :http | :websocket,
          pid: pid() | nil,
          monitor: reference() | nil,
          socket_delivery: Exiron.Hub.Delivery.t() | nil,
          http_delivery: Exiron.Hub.Delivery.t() | nil,
          listen?: boolean(),
          listen_mode: boolean() | :all,
          connected_at: DateTime.t() | nil
        }

  defstruct client_identity: nil,
            runtime_ref: nil,
            last_ack_ref: nil,
            http_batch_ref: nil,
            client_id: nil,
            lease: nil,
            timer: nil,
            transport: :http,
            pid: nil,
            monitor: nil,
            socket_delivery: nil,
            http_delivery: nil,
            listen?: false,
            listen_mode: false,
            connected_at: nil

  @spec new(
          client_id :: String.t(),
          lease :: term(),
          timer :: reference() | nil,
          options :: keyword()
        ) :: t()
  def new(client_id, lease, timer, options \\ []) do
    %__MODULE__{
      runtime_ref:
        Keyword.get_lazy(options, :runtime_ref, fn ->
          :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        end),
      http_batch_ref: Keyword.get(options, :http_batch_ref),
      last_ack_ref: Keyword.get(options, :last_ack_ref),
      client_id: client_id,
      client_identity:
        Exiron.Hub.ClientIdentity.normalize(Keyword.get(options, :client_identity)),
      lease: lease,
      timer: timer,
      transport: Keyword.get(options, :transport, :http),
      pid: Keyword.get(options, :pid),
      monitor: Keyword.get(options, :monitor),
      socket_delivery: Keyword.get(options, :socket_delivery),
      http_delivery: Keyword.get(options, :http_delivery),
      listen?: Keyword.get(options, :listen?, false),
      listen_mode: Keyword.get(options, :listen_mode, false),
      connected_at: Keyword.get(options, :connected_at)
    }
  end
end
