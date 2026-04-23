defmodule BullXGateway.AdapterSupervisorTest do
  use ExUnit.Case, async: false

  alias BullXGateway.AdapterRegistry
  alias BullXGateway.AdapterSupervisor

  defmodule SupervisedAdapter do
    @behaviour BullXGateway.Adapter

    @impl true
    def adapter_id, do: :supervised_adapter

    @impl true
    def child_specs(_channel, config) do
      [
        %{
          id: Agent,
          start: {Agent, :start_link, [fn -> config.test_pid end]}
        }
      ]
    end

    @impl true
    def capabilities, do: []
  end

  test "start_channel starts a per-channel subtree and registers its anchor pid" do
    channel = {:supervised_adapter, "channel-#{System.unique_integer([:positive])}"}

    on_exit(fn -> AdapterSupervisor.stop_channel(channel) end)

    assert {:ok, pid} =
             AdapterSupervisor.start_channel(channel, SupervisedAdapter, %{
               test_pid: self(),
               dedupe_ttl_ms: 123
             })

    assert is_pid(pid)
    assert AdapterSupervisor.whereis_channel(channel) == pid
    assert %{active: 1, supervisors: 0, workers: 1} = Supervisor.count_children(pid)

    assert {:ok,
            %{
              module: SupervisedAdapter,
              config: %{anchor_pid: ^pid, dedupe_ttl_ms: 123}
            }} = AdapterRegistry.lookup(channel)
  end
end
