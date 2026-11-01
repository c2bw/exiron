defmodule Exiron.Hub.Transition do
  @moduledoc false

  alias Exiron.Hub.Effect

  defstruct next_state: nil, reply: nil, effects: []

  @type t :: %__MODULE__{
          next_state: term(),
          reply: term() | nil,
          effects: [Effect.t()]
        }

  @spec new(term(), keyword()) :: t()
  def new(next_state, opts \\ []) do
    %__MODULE__{
      next_state: next_state,
      reply: Keyword.get(opts, :reply),
      effects: Keyword.get(opts, :effects, [])
    }
  end

  @spec reply(t() | term(), term()) :: t()
  def reply(%__MODULE__{} = transition, reply), do: %{transition | reply: reply}
  def reply(next_state, reply), do: new(next_state, reply: reply)

  @spec effect(t(), Effect.t()) :: t()
  def effect(%__MODULE__{effects: effects} = transition, effect) do
    %{transition | effects: effects ++ [effect]}
  end

  @spec effects(t(), [Effect.t()]) :: t()
  def effects(%__MODULE__{} = transition, effects), do: %{transition | effects: effects}

  @spec prepend_effect(t(), Effect.t()) :: t()
  def prepend_effect(%__MODULE__{effects: effects} = transition, effect) do
    %{transition | effects: [effect | effects]}
  end
end
