defmodule ExironClient.SocketCallback do
  @moduledoc false

  alias WebSockex.BadResponseError

  def invoke(module, function, arguments) do
    {:return, apply(module, function, arguments)}
  rescue
    exception -> {:exit, {exception, __STACKTRACE__}}
  catch
    :exit, reason -> {:exit, reason}
    kind, reason -> {:exit, {kind, reason}}
  end

  def terminate(module, reason, callback_state) do
    apply(module, :terminate, [reason, callback_state])
  catch
    _, _reason -> :ok
  end

  def bad_response(module, function, arguments, response) do
    %BadResponseError{
      module: module,
      function: function,
      args: arguments,
      response: response
    }
  end
end
