defmodule BullXFeishu.Adapter do
  @moduledoc """
  Gateway adapter implementation for Feishu/Lark.
  """

  @behaviour BullXGateway.Adapter

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXFeishu.{Channel, Config, Delivery, StreamingCard}

  @impl true
  def adapter_id, do: :feishu

  @impl true
  def capabilities, do: [:send, :edit, :stream, :cards, :threads, :reactions]

  @impl true
  def child_specs(channel, config) do
    cfg = Config.normalize!(channel, config)

    children = [
      {Channel, {channel, cfg}}
    ]

    if cfg.start_transport? do
      children ++ transport_children(channel, cfg)
    else
      children
    end
  end

  @impl true
  def deliver(%GatewayDelivery{} = delivery, %{channel: channel, config: config}) do
    with {:ok, cfg} <- Config.normalize(channel, config) do
      Delivery.deliver(delivery, cfg)
    end
  end

  @impl true
  def stream(%GatewayDelivery{} = delivery, enumerable, %{channel: channel, config: config}) do
    with {:ok, cfg} <- Config.normalize(channel, config) do
      StreamingCard.stream(delivery, enumerable, cfg)
    end
  end

  defp transport_children(channel, %Config{connection_mode: :websocket} = config) do
    [
      %{
        id: {FeishuOpenAPI.WS.Client, channel},
        start:
          {FeishuOpenAPI.WS.Client, :start_link,
           [
             [
               client: Config.client!(config),
               dispatcher: Channel.event_dispatcher(channel, config),
               name: Channel.transport_via({FeishuOpenAPI.WS.Client, channel})
             ]
           ]},
        restart: :permanent,
        type: :worker
      }
    ]
  end

  defp transport_children(channel, %Config{connection_mode: :webhook, webhook: webhook} = config)
       when is_map(webhook) do
    [
      %{
        id: {Bandit, channel},
        start:
          {Bandit, :start_link,
           [
             [
               plug: {BullXFeishu.WebhookPlug, [channel: channel, config: config]},
               scheme: webhook.scheme,
               thousand_island_options: [
                 port: webhook.port,
                 transport_options: [ip: parse_host(webhook.host)]
               ]
             ]
           ]},
        restart: :permanent,
        type: :worker
      }
    ]
  end

  defp transport_children(_channel, %Config{connection_mode: :webhook}), do: []

  defp parse_host(host) when is_tuple(host), do: host

  defp parse_host(host) when is_binary(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> address
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  defp parse_host(_), do: {127, 0, 0, 1}
end
