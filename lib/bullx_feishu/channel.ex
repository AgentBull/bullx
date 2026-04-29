defmodule BullXFeishu.Channel do
  @moduledoc false

  use GenServer
  require Logger

  alias BullXFeishu.{Cache, Config, EventListener}
  alias FeishuOpenAPI.Event.Dispatcher

  defstruct [:channel, :config, :cache]

  def child_spec({channel, config}) do
    %{
      id: {__MODULE__, channel},
      start: {__MODULE__, :start_link, [{channel, config}]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link({channel, config}) do
    GenServer.start_link(__MODULE__, {channel, config}, name: via(channel))
  end

  def handle_event(channel, event_type, event) do
    GenServer.call(via(channel), {:event, event_type, event}, 30_000)
  end

  def handle_card_action(channel, action) do
    GenServer.call(via(channel), {:card_action, action}, 30_000)
  end

  def transport_status(channel) do
    transport_key = {FeishuOpenAPI.WS.Client, channel}

    case Registry.lookup(BullXGateway.AdapterSupervisor.Registry, transport_key) do
      [{pid, _value}] when is_pid(pid) -> FeishuOpenAPI.WS.Client.status(pid)
      [] -> :not_started
    end
  catch
    :exit, _reason -> :down
  end

  def event_dispatcher(channel, %Config{} = config) do
    [client: Config.client!(config)]
    |> Dispatcher.new()
    |> register_event_handlers(channel)
  end

  def transport_via(key), do: {:via, Registry, {BullXGateway.AdapterSupervisor.Registry, key}}

  @impl true
  def init({channel, config}) do
    {:ok, cfg} = Config.normalize(channel, config)

    Logger.info("feishu channel start requested",
      channel: :feishu,
      channel_id: cfg.channel_id,
      transport: :websocket,
      domain: inspect(cfg.domain)
    )

    {:ok, %__MODULE__{channel: channel, config: cfg, cache: Cache.new()}}
  end

  @impl true
  def handle_call({:event, event_type, event}, _from, state) do
    {reply, state} = EventListener.handle_event(event_type, event, state)
    {:reply, reply, state}
  end

  def handle_call({:card_action, action}, _from, state) do
    {reply, state} = EventListener.handle_card_action(action, state)
    {:reply, reply, state}
  end

  defp via(channel),
    do: {:via, Registry, {BullXGateway.AdapterSupervisor.Registry, {__MODULE__, channel}}}

  defp register_event_handlers(%Dispatcher{} = dispatcher, channel) do
    [
      "im.message.receive_v1",
      "im.message.updated_v1",
      "im.message.recalled_v1",
      "im.message.reaction.created_v1",
      "im.message.reaction.deleted_v1"
    ]
    |> Enum.reduce(dispatcher, fn event_type, acc ->
      Dispatcher.on(acc, event_type, fn type, event -> handle_event(channel, type, event) end)
    end)
  end
end
