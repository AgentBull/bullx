defmodule BullXGateway.AdapterSupervisorTest do
  use ExUnit.Case, async: false

  alias BullXGateway.AdapterRegistry
  alias BullXGateway.AdapterSupervisor

  defmodule SupervisedAdapter do
    @behaviour BullXGateway.Adapter

    @impl true
    def adapter_id, do: :supervised_adapter

    @impl true
    def config_docs, do: %{"en-US" => "https://example.test/supervised-adapter"}

    @impl true
    def connectivity_check(_channel, _config), do: {:ok, %{"status" => "ok"}}

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

  setup do
    AdapterRegistry.entries()
    |> Enum.filter(fn {_channel, entry} -> entry.module == SupervisedAdapter end)
    |> Enum.each(fn {channel, _entry} -> AdapterSupervisor.stop_channel(channel) end)

    :ok
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
              managed?: true,
              config: %{anchor_pid: ^pid, dedupe_ttl_ms: 123}
            }} = AdapterRegistry.lookup(channel)
  end

  test "reconcile_configured_channels starts missing configured channels" do
    channel = {:supervised_adapter, "channel-#{System.unique_integer([:positive])}"}

    on_exit(fn -> AdapterSupervisor.stop_channel(channel) end)

    assert :ok =
             AdapterSupervisor.reconcile_configured_channels([
               {channel, SupervisedAdapter, %{test_pid: self(), dedupe_ttl_ms: 234}}
             ])

    assert pid = AdapterSupervisor.whereis_channel(channel)

    assert {:ok,
            %{
              module: SupervisedAdapter,
              managed?: true,
              config: %{anchor_pid: ^pid, dedupe_ttl_ms: 234}
            }} = AdapterRegistry.lookup(channel)
  end

  test "reconcile_configured_channels restarts changed channel config" do
    channel = {:supervised_adapter, "channel-#{System.unique_integer([:positive])}"}

    on_exit(fn -> AdapterSupervisor.stop_channel(channel) end)

    assert :ok =
             AdapterSupervisor.reconcile_configured_channels([
               {channel, SupervisedAdapter, %{test_pid: self(), dedupe_ttl_ms: 345}}
             ])

    old_pid = AdapterSupervisor.whereis_channel(channel)
    assert is_pid(old_pid)

    assert :ok =
             AdapterSupervisor.reconcile_configured_channels([
               {channel, SupervisedAdapter, %{test_pid: self(), dedupe_ttl_ms: 456}}
             ])

    new_pid = AdapterSupervisor.whereis_channel(channel)
    assert is_pid(new_pid)
    refute new_pid == old_pid
    refute Process.alive?(old_pid)

    assert {:ok,
            %{
              module: SupervisedAdapter,
              config: %{anchor_pid: ^new_pid, dedupe_ttl_ms: 456}
            }} = AdapterRegistry.lookup(channel)
  end

  test "reconcile_configured_channels stops removed managed channels" do
    channel = {:supervised_adapter, "channel-#{System.unique_integer([:positive])}"}

    assert {:ok, pid} =
             AdapterSupervisor.start_channel(channel, SupervisedAdapter, %{test_pid: self()})

    assert is_pid(pid)

    assert :ok = AdapterSupervisor.reconcile_configured_channels([])

    wait_until(fn -> is_nil(AdapterSupervisor.whereis_channel(channel)) end)
    assert :error = AdapterRegistry.lookup(channel)
  end

  test "reconcile_configured_channels leaves directly registered channels alone" do
    channel = {:supervised_adapter, "manual-#{System.unique_integer([:positive])}"}

    on_exit(fn -> AdapterRegistry.unregister(channel) end)

    assert :ok = AdapterRegistry.register(channel, SupervisedAdapter, %{test_pid: self()})
    assert :ok = AdapterSupervisor.reconcile_configured_channels([])

    assert {:ok, %{module: SupervisedAdapter, managed?: false}} = AdapterRegistry.lookup(channel)
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      true ->
        :ok

      false ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met before timeout")
end
