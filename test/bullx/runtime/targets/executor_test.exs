defmodule BullX.Runtime.Targets.ExecutorTest do
  use ExUnit.Case, async: true

  alias BullX.Runtime.Targets.Executor
  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Target

  test "blackhole targets terminate without creating a chat session" do
    assert {:ok, %{blackholed: true}} =
             Executor.execute(
               %{
                 source: :db_route,
                 route: %InboundRoute{key: "deny"},
                 target: %Target{key: "deny-target", kind: "blackhole", name: "Deny", config: %{}}
               },
               signal()
             )
  end

  defp signal do
    Jido.Signal.new!(%{
      id: "sig-executor",
      source: "/test",
      type: "com.agentbull.x.inbound.received",
      data: %{"scope_id" => "scope", "thread_id" => nil},
      extensions: %{"bullx_channel_adapter" => "feishu", "bullx_channel_id" => "default"}
    })
  end
end
