defmodule BullXGateway.Inputs.Action do
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
    :action_id,
    values: %{},
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
          action_id: String.t() | nil,
          values: map(),
          refs: [BullXGateway.Inputs.ref()]
        }
end
