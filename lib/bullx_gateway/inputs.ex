defmodule BullXGateway.Inputs do
  @moduledoc false

  @type actor :: %{
          required(:id) => String.t(),
          required(:display) => String.t(),
          required(:bot) => boolean(),
          optional(:app_user_id) => String.t() | nil
        }

  @type ref :: %{
          required(:kind) => String.t(),
          required(:id) => String.t(),
          optional(:url) => String.t() | nil
        }

  @type adapter_event :: %{
          required(:type) => String.t(),
          required(:version) => non_neg_integer(),
          required(:data) => map()
        }

  @type reply_channel :: %{
          required(:adapter) => atom(),
          required(:tenant) => String.t(),
          required(:scope_id) => String.t(),
          required(:thread_id) => String.t() | nil
        }

  @type content_block :: BullXGateway.Delivery.Content.t() | map()
end
