defmodule BullXGateway.Adapter do
  @moduledoc false

  @type context :: %{
          required(:channel) => BullXGateway.Delivery.channel(),
          required(:config) => map(),
          required(:telemetry) => map(),
          optional(atom()) => term()
        }

  @type op_capability :: :send | :edit | :stream
  @type metadata_capability :: :reactions | :cards | :threads | atom()
  @type capability :: op_capability() | metadata_capability()

  @callback adapter_id() :: atom()
  @callback child_specs(channel :: BullXGateway.Delivery.channel(), config :: map()) ::
              [Supervisor.child_spec()]
  @callback deliver(BullXGateway.Delivery.t(), context()) ::
              {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}
  @callback stream(BullXGateway.Delivery.t(), Enumerable.t(), context()) ::
              {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}
  @callback capabilities() :: [capability()]

  @optional_callbacks child_specs: 2, deliver: 2, stream: 3
end
