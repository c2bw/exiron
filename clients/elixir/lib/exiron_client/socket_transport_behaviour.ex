defmodule ExironClient.SocketTransportBehaviour do
  @moduledoc false

  @callback start_link(binary(), module(), map(), keyword()) :: GenServer.on_start()
  @callback set_active(WebSockex.Conn.t(), boolean() | :once) :: :ok | {:error, term()}
end
