defmodule BullXFeishu do
  @moduledoc """
  Feishu/Lark Gateway channel adapter namespace.

  Feishu is a first-class Gateway integration, not a separate OTP
  application. The modules under this namespace translate Feishu transport
  events and delivery calls at the Gateway boundary while keeping Feishu actor
  identities channel-local.
  """

  @adapter :feishu

  @spec adapter_id() :: :feishu
  def adapter_id, do: @adapter

  @spec channel(String.t()) :: BullXGateway.Delivery.channel()
  def channel(channel_id) when is_binary(channel_id), do: {@adapter, channel_id}
end
