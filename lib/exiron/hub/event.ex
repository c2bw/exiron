defmodule Exiron.Hub.Event do
  @moduledoc false

  defstruct [:direction, :target, :hook, :message, :kind]

  def new(direction, target, hook, message, kind) do
    %__MODULE__{
      direction: direction,
      target: target,
      hook: hook,
      message: message,
      kind: kind
    }
  end
end
