defmodule BullX.ApplicationTest do
  use ExUnit.Case, async: false

  @required_processes [
    BullX.Config.Supervisor,
    BullX.Config.Cache,
    BullXAccounts.AuthZ.Cache,
    BullX.Skills.Supervisor,
    BullXBrain.Supervisor,
    BullX.Runtime.Supervisor,
    BullXGateway.CoreSupervisor,
    BullXGateway.AdapterSupervisor
  ]

  test "application boots the required named processes" do
    for name <- @required_processes do
      assert is_pid(lookup_pid(name)), "#{inspect(name)} is not running"
    end
  end

  defp lookup_pid(BullX.Config.Cache), do: GenServer.whereis(BullX.Config.Cache)
  defp lookup_pid(name), do: Process.whereis(name)
end
