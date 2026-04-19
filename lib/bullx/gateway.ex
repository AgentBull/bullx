defmodule BullX.Gateway do
  @moduledoc """
  Multi-transport ingress and egress. Normalizes inbound events from external
  sources (HTTP polling, subscribed WebSockets, webhooks, channel adapters like
  Feishu/Slack/Telegram) into internal signals, and dispatches outbound
  messages back to those destinations.

  RFC-000 establishes the namespace and an empty top-level supervisor; transport
  adapters are added by later RFCs.
  """
end
