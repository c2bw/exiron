defmodule Exiron.Hub.Telegram do
  @moduledoc false

  alias Exiron.Hub.Message
  alias Exiron.Hub.Telegram.BotRegistry
  alias Exiron.Hub.Telegram.Outbound
  alias Exiron.Hub.Telegram.Pollers
  alias Exiron.Hub.Telegram.Sender

  @service_id 222

  @derive {Inspect, only: []}
  defstruct bots: %BotRegistry{}, sender: nil, poller_bot_name_updater: nil

  def new(configs, opts \\ []) do
    %__MODULE__{
      bots: BotRegistry.new(configs),
      sender: Keyword.get(opts, :sender, &Sender.deliver/2),
      poller_bot_name_updater:
        Keyword.get(opts, :poller_bot_name_updater, &Pollers.put_bot_name/2)
    }
  end

  def configs(%__MODULE__{bots: bots}), do: BotRegistry.configs(bots)

  def start_pollers(%__MODULE__{bots: bots}, enabled?),
    do: bots |> BotRegistry.poller_bots() |> Pollers.start(enabled?)

  def stop_pollers, do: Pollers.stop()

  def poller_tokens(%__MODULE__{bots: bots}), do: BotRegistry.poller_tokens(bots)

  def poller_bot_name(%__MODULE__{bots: bots}, token),
    do: BotRegistry.poller_bot_name(bots, token)

  def bot_snapshots(%__MODULE__{bots: bots}), do: BotRegistry.snapshots(bots)

  def missing_identity_tokens(%__MODULE__{bots: bots}),
    do: BotRegistry.missing_identity_tokens(bots)

  def missing_bot_name_tokens(%__MODULE__{bots: bots}),
    do: BotRegistry.missing_bot_name_tokens(bots)

  def put_bot_name(%__MODULE__{} = telegram, token, bot_name)
      when is_binary(token) and is_binary(bot_name) do
    put_bot_identity(telegram, token, %{bot_name: bot_name})
  end

  def put_bot_name(%__MODULE__{} = telegram, _token, _bot_name), do: telegram

  def put_bot_identity(%__MODULE__{} = telegram, token, identity) when is_binary(token) do
    %{telegram | bots: BotRegistry.put_identity(telegram.bots, token, identity)}
  end

  def put_bot_identity(%__MODULE__{} = telegram, _token, _identity), do: telegram

  def update_poller_bot_name(%__MODULE__{poller_bot_name_updater: updater}, token, bot_name),
    do: updater.(token, bot_name)

  def update_poller_bot_name(token, bot_name), do: Pollers.put_bot_name(token, bot_name)

  def membership_targets(%__MODULE__{bots: bots}), do: BotRegistry.membership_targets(bots)

  def bot_tag(bot_name), do: BotRegistry.bot_tag(bot_name)

  def send_message(%__MODULE__{} = telegram, %Message{} = message) do
    Outbound.send(telegram.bots, telegram.sender, message)
  end

  def annotate_message(%__MODULE__{} = telegram, %Message{} = message) do
    Outbound.annotate(telegram.bots, message)
  end

  def bot_for_name(%__MODULE__{bots: bots}, chat_id, bot_name),
    do: BotRegistry.bot_for_name(bots, chat_id, bot_name)

  def default_bot_name(%__MODULE__{bots: bots}, chat_id),
    do: BotRegistry.default_bot_name(bots, chat_id)

  def service_id, do: @service_id

  def token_fingerprint(token), do: BotRegistry.token_fingerprint(token)
end
