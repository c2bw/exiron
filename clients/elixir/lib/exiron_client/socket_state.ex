defmodule ExironClient.SocketState do
  @moduledoc false

  alias ExironClient.{Protocol, SocketTransport}

  @type t :: %__MODULE__{
          client: ExironClient.t() | map() | nil,
          handler_options: keyword(),
          handler: (ExironClient.Message.t() -> term()) | nil,
          interval_ms: pos_integer() | nil,
          disconnect_timeout_ms: pos_integer() | nil,
          on_connect: (-> term()) | nil,
          on_protocol: (Protocol.t() -> term()) | nil,
          on_disconnect: (term() -> term()) | nil,
          connected?: boolean(),
          connection_state: atom(),
          conn: term(),
          last_seen_ms: integer() | nil,
          last_error: term(),
          reconnect_started_at_ms: integer() | nil,
          worker_pid: pid() | nil,
          worker_monitor_ref: reference() | nil,
          worker_job_ref: reference() | nil,
          worker_delivery_id: binary() | nil,
          socket_paused?: boolean(),
          socket_transport: module(),
          ping_ref: reference() | nil,
          ping_timer_ref: reference() | nil,
          protocol: Protocol.t()
        }

  @derive {Inspect,
           only: [
             :connected?,
             :connection_state,
             :last_seen_ms,
             :last_error,
             :reconnect_started_at_ms,
             :worker_pid,
             :worker_job_ref,
             :socket_paused?,
             :protocol
           ]}
  defstruct runtime_status: nil,
            graceful_shutdown: false,
            client_drain: nil,
            retire_task: nil,
            last_delivery_id: nil,
            client: nil,
            handler: nil,
            handler_options: [],
            interval_ms: nil,
            disconnect_timeout_ms: nil,
            on_connect: nil,
            on_protocol: nil,
            on_disconnect: nil,
            connected?: false,
            connection_state: :disconnected,
            conn: nil,
            last_seen_ms: nil,
            last_error: nil,
            reconnect_started_at_ms: nil,
            worker_pid: nil,
            worker_monitor_ref: nil,
            worker_job_ref: nil,
            worker_delivery_id: nil,
            socket_paused?: false,
            socket_transport: SocketTransport,
            ping_ref: nil,
            ping_timer_ref: nil,
            protocol: %Protocol{}
end
