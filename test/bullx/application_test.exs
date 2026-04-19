defmodule BullX.ApplicationTest do
  use ExUnit.Case, async: false

  @supervisors [
    BullX.Skills.Supervisor,
    BullX.Brain.Supervisor,
    BullX.Runtime.Supervisor,
    BullX.Gateway.Supervisor
  ]

  test "each subsystem supervisor is running under the application" do
    for sup <- @supervisors do
      assert is_pid(Process.whereis(sup)), "#{inspect(sup)} is not running"
    end
  end

  test "each subsystem supervisor boots with zero children" do
    for sup <- @supervisors do
      assert %{active: 0, specs: 0, workers: 0, supervisors: 0} =
               Supervisor.count_children(sup)
    end
  end

  test "BullX.Config.Supervisor and BullX.Config.Cache are running" do
    assert is_pid(Process.whereis(BullX.Config.Supervisor)),
           "BullX.Config.Supervisor is not running"

    assert is_pid(GenServer.whereis(BullX.Config.Cache)),
           "BullX.Config.Cache is not running"
  end
end
