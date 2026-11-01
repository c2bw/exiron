defmodule Exiron.HubCase do
  use ExUnit.CaseTemplate

  import Exiron.Support.RouterHelper

  alias Exiron.Hub
  alias Exiron.Hub.Telegram

  using do
    quote do
      import Exiron.HubCase
      import Exiron.Support.Eventually
      import Exiron.Support.RouterHelper
    end
  end

  setup do
    router = load_router!()

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: telegram_sender(self())
      )

    :ok = Hub.configure(router, telegram)
    :ok
  end

  def start_socket_process do
    start_supervised!(
      {Task, fn -> receive do: (:stop -> :ok) end},
      id: make_ref(),
      restart: :temporary
    )
  end

  def load_router! do
    load_router!("hub")
  end

  def load_push_router! do
    load_router!("hub-push", """
    aliases:
      telegram:
        home: 123
    routes:
      home:
        middleware:
          - family
        push: true
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "ai-token"
    """)
  end

  def load_default_bot_push_router! do
    load_router!("hub-default-bot-push", """
    aliases:
      telegram:
        home: 123
    routes:
      home:
        middleware:
          - family
        push: true
        default_bot: second-bot
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "ai-token"
    """)
  end

  def load_multi_push_router! do
    load_router!("hub-multi-push", """
    aliases:
      telegram:
        home: 123
        work: 456
    routes:
      home:
        middleware:
          - family
        push: true
      work:
        middleware:
          - family
        push: true
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "ai-token"
    """)
  end

  def multi_bot_telegram(parent) do
    Telegram.new(
      [
        %{chat_id: 123, bot_token: "first-token", bot_name: "first-bot"},
        %{chat_id: 123, bot_token: "second-token", bot_name: "second-bot"}
      ],
      sender: telegram_sender(parent)
    )
  end

  def telegram_sender(parent) do
    fn token, message ->
      send(parent, {:telegram_sent, token, message})
      :ok
    end
  end

  def expire_client(hook, client_id \\ "default") do
    %{client_id: ^client_id, lease: lease} = :sys.get_state(Hub).delivery.clients[hook]
    send(Hub, {:expire_client, hook, client_id, lease})
    _ = :sys.get_state(Hub)
  end

  def with_send_supervisor_stopped(fun) do
    :ok = Supervisor.terminate_child(Exiron.Hub.Supervisor, Exiron.Hub.SendSupervisor)

    try do
      fun.()
    after
      {:ok, _pid} =
        Supervisor.restart_child(Exiron.Hub.Supervisor, Exiron.Hub.SendSupervisor)
    end
  end
end
