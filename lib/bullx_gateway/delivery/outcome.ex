defmodule BullXGateway.Delivery.Outcome do
  @moduledoc false

  @type status :: :sent | :edited | :stream_closed | :degraded

  @type adapter_success_t :: %{
          required(:status) => status(),
          optional(:external_id) => String.t(),
          optional(:warnings) => [String.t()],
          optional(atom()) => term()
        }
end
