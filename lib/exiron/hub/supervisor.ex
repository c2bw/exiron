defmodule Exiron.Hub.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Exiron.Hub.TelegramSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Exiron.Hub.SendSupervisor},
      {Task.Supervisor, name: Exiron.Hub.LookupSupervisor},
      Supervisor.child_spec({Task.Supervisor, name: Exiron.Hub.CallbackAnswers, max_children: 64},
        id: Exiron.Hub.CallbackAnswers
      ),
      Exiron.Hub.BotLookupTasks,
      Exiron.Hub.Telegram.SendCoordinator,
      Exiron.Hub
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
