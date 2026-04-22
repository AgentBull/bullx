defmodule BullXGateway.Inputs.Trigger do
  @moduledoc false

  @enforce_keys [:id, :source, :channel, :scope_id, :thread_id, :actor, :event]
  defstruct [
    :id,
    :source,
    :subject,
    :time,
    :channel,
    :scope_id,
    :thread_id,
    :actor,
    :event,
    refs: [],
    content: []
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
          event: BullXGateway.Inputs.event(),
          refs: [BullXGateway.Inputs.ref()],
          content: [BullXGateway.Inputs.content_block()]
        }
end
