defmodule BullXGateway.CoreSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    children = [
      {Task.Supervisor, name: BullXGateway.PolicyTaskSupervisor},
      {Task.Supervisor, name: BullXGateway.Dispatcher.TaskSupervisor},
      {BullXGateway.ControlPlane, store: BullXGateway.ControlPlane.Store.Postgres},
      {Jido.Signal.Bus, name: BullXGateway.SignalBus},
      BullXGateway.AdapterRegistry,
      BullXGateway.Deduper,
      BullXGateway.OutboundDeduper,
      BullXGateway.ScopeRegistry,
      BullXGateway.Dispatcher,
      BullXGateway.DLQ.ReplaySupervisor,
      BullXGateway.Retention,
      BullXGateway.ControlPlane.InboundReplay,
      BullXGateway.Telemetry
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
