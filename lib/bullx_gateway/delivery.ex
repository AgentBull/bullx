defmodule BullXGateway.Delivery do
  @moduledoc """
  Minimal outbound delivery carrier shared by Gateway inbound and outbound code.
  """

  alias BullXGateway.Delivery.Content

  @type channel :: {atom(), String.t()}
  @type op :: :send | :edit | :stream

  @type t :: %__MODULE__{
          id: String.t(),
          channel: channel(),
          op: op(),
          scope_id: String.t(),
          thread_id: String.t() | nil,
          target_id: String.t() | nil,
          content: [Content.t()],
          metadata: map()
        }

  defstruct [
    :id,
    :channel,
    :op,
    :scope_id,
    :thread_id,
    :target_id,
    content: [],
    metadata: %{}
  ]
end
