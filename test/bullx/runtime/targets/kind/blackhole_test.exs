defmodule BullX.Runtime.Targets.Kind.BlackholeTest do
  use ExUnit.Case, async: true

  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Kind.Blackhole
  alias BullX.Runtime.Targets.Target

  test "returns terminal blackhole result and emits safe telemetry" do
    handler_id = "blackhole-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:bullx, :runtime, :targets, :target_blackholed],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:blackholed, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{blackholed: true}} =
             Blackhole.run(%{
               target: %Target{key: "deny", kind: "blackhole", name: "Deny", config: %{}},
               route: %InboundRoute{key: "deny-route"},
               signal: signal()
             })

    assert_receive {:blackholed,
                    %{target_key: "deny", route_key: "deny-route", signal_id: "sig-blackhole"}}
  end

  defp signal do
    Jido.Signal.new!(%{
      id: "sig-blackhole",
      source: "/test",
      type: "com.agentbull.x.inbound.received",
      data: %{"scope_id" => "scope", "thread_id" => nil},
      extensions: %{"bullx_channel_adapter" => "feishu", "bullx_channel_id" => "default"}
    })
  end
end
