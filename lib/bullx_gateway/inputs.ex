defmodule BullXGateway.Inputs do
  @moduledoc """
  Shared type vocabulary for canonical inbound adapter inputs.

  Adapters submit one of the `BullXGateway.Inputs.*` structs before Gateway
  renders the final `com.agentbull.x.inbound.received` signal. The types here
  describe the stable pieces shared across all inbound categories: actor
  identity, opaque event facts, reply routing, references, and content blocks.
  """

  @type actor :: %{
          required(:id) => String.t(),
          required(:display) => String.t(),
          required(:bot) => boolean()
        }

  @type ref :: %{
          required(:kind) => String.t(),
          required(:id) => String.t(),
          optional(:url) => String.t() | nil
        }

  @type event :: %{
          required(:name) => String.t(),
          required(:version) => non_neg_integer(),
          required(:data) => map()
        }

  @type reply_channel :: %{
          required(:adapter) => atom(),
          required(:channel_id) => String.t(),
          required(:scope_id) => String.t(),
          required(:thread_id) => String.t() | nil
        }

  @type content_block :: BullXGateway.Delivery.Content.t() | map()
end
