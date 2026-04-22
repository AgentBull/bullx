defmodule BullXGateway.Inputs.Reaction do
  @moduledoc false

  @enforce_keys [
    :id,
    :source,
    :channel,
    :scope_id,
    :thread_id,
    :actor,
    :adapter_event,
    :reply_channel
  ]
  defstruct [
    :id,
    :source,
    :subject,
    :time,
    :channel,
    :scope_id,
    :thread_id,
    :actor,
    :adapter_event,
    :reply_channel,
    :target_external_message_id,
    :emoji,
    :action,
    :agent_text,
    refs: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          source: String.t(),
          subject: String.t() | nil,
          time: DateTime.t() | nil,
          channel: BullXGateway.Delivery.channel(),
          scope_id: String.t(),
          thread_id: String.t() | nil,
          actor: BullXGateway.Inputs.actor(),
          adapter_event: BullXGateway.Inputs.adapter_event(),
          reply_channel: BullXGateway.Inputs.reply_channel(),
          target_external_message_id: String.t() | nil,
          emoji: String.t() | nil,
          action: :added | :removed | String.t() | nil,
          agent_text: String.t() | nil,
          refs: [BullXGateway.Inputs.ref()]
        }
end
