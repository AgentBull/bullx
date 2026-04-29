defmodule BullX.Runtime.Targets.IngressTest do
  use BullX.DataCase, async: false

  alias BullX.Runtime.Targets.Cache
  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Target
  alias BullX.Runtime.Targets.Writer
  alias Jido.Signal.Bus

  setup do
    allow_cache(Cache)
    Repo.delete_all(InboundRoute)
    Repo.delete_all(Target)
    Cache.refresh_all()
    on_exit(fn -> Cache.refresh_all() end)
    :ok
  end

  test "subscribed ingress dispatches Gateway inbound signals" do
    assert {:ok, target} =
             Writer.put_target(%{
               key: "deny",
               kind: "blackhole",
               name: "Deny",
               config: %{}
             })

    assert {:ok, _route} =
             Writer.put_inbound_route(%{
               key: "deny-feishu",
               name: "Deny Feishu",
               priority: 100,
               adapter: "feishu",
               target_key: target.key
             })

    handler_id = "ingress-blackhole-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:bullx, :runtime, :targets, :target_blackholed],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:blackholed, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _recorded} = Bus.publish(BullXGateway.SignalBus, [signal()])
    assert_receive {:blackholed, %{target_key: "deny", route_key: "deny-feishu"}}, 500
  end

  defp signal do
    Jido.Signal.new!(%{
      id: "sig-ingress",
      source: "bullx://gateway/feishu/default",
      type: "com.agentbull.x.inbound.received",
      data: %{
        "duplex" => true,
        "scope_id" => "chat_a",
        "thread_id" => nil,
        "reply_channel" => %{
          "adapter" => "feishu",
          "channel_id" => "default",
          "scope_id" => "chat_a",
          "thread_id" => nil
        },
        "actor" => %{"id" => "ou_a"},
        "event" => %{"type" => "message", "name" => "feishu.message.created"},
        "content" => [%{"kind" => "text", "body" => %{"text" => "hello"}}]
      },
      extensions: %{
        "bullx_channel_adapter" => "feishu",
        "bullx_channel_id" => "default"
      }
    })
  end

  defp allow_cache(cache_module) do
    case Process.whereis(cache_module) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
