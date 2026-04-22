defmodule BullXGateway.PolicyRunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BullXGateway.PolicyRunner

  test "normalizes raised policy errors without task crash logs" do
    log =
      capture_log(fn ->
        assert {:error, {:raised, "boom"}} =
                 PolicyRunner.run(fn -> raise("boom") end, 50)
      end)

    refute log =~ "Task #PID"
    refute log =~ "(RuntimeError) boom"
  end
end
