defmodule Exiron.Hub.SendTask do
  @moduledoc false

  @type t :: %__MODULE__{
          from: GenServer.from() | nil,
          command: Exiron.Hub.SendCommand.t(),
          pid: pid(),
          monitor: reference(),
          timer: reference(),
          started_at: integer() | nil
        }

  defstruct diagnostic: nil,
            attempt_in_flight?: false,
            from: nil,
            command: nil,
            pid: nil,
            monitor: nil,
            timer: nil,
            started_at: nil

  @spec new(
          from :: GenServer.from() | nil,
          command :: Exiron.Hub.SendCommand.t(),
          pid :: pid(),
          monitor :: reference(),
          timer :: reference()
        ) :: t()
  def new(from, command, pid, monitor, timer) do
    %__MODULE__{
      from: from,
      command: command,
      pid: pid,
      monitor: monitor,
      timer: timer,
      started_at: System.monotonic_time()
    }
  end
end
