defmodule BullX.Runtime.Targets.SessionKeyTest do
  use ExUnit.Case, async: true

  alias BullX.Runtime.Targets.SessionKey
  alias Jido.Signal

  test "derives stable key with default thread sentinel" do
    signal =
      Signal.new!(%{
        type: "com.agentbull.x.inbound.received",
        source: "/test",
        data: %{"scope_id" => "scope", "thread_id" => nil},
        extensions: %{
          "bullx_channel_adapter" => "feishu",
          "bullx_channel_id" => "default"
        }
      })

    assert SessionKey.from_signal("main", signal) ==
             {:ok, {"main", "feishu", "default", "scope", SessionKey.default_thread()}}
  end
end
