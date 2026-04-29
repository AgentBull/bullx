defmodule BullX.Runtime.Targets.RouterTest do
  use ExUnit.Case, async: true

  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Router
  alias BullX.Runtime.Targets.Target
  alias Jido.Signal

  test "empty route table resolves to built-in main fallback" do
    assert {:ok, %{source: :fallback, route: :main, target: %Target{} = target}} =
             Router.resolve(inbound_signal(), %{
               router: Router.empty(),
               routes: %{},
               targets: %{}
             })

    assert target.key == "main"
    assert target.kind == "agentic_chat_loop"
  end

  test "fixed match columns cover adapter channel scope thread actor and event fields" do
    route = %InboundRoute{
      adapter: "feishu",
      channel_id: "default",
      scope_id: "chat_a",
      thread_id: "thread_a",
      actor_id: "ou_a",
      event_type: "message",
      event_name_prefix: "feishu.message."
    }

    assert Router.match_route?(route, inbound_signal())
    refute Router.match_route?(%{route | actor_id: "ou_b"}, inbound_signal())
    refute Router.match_route?(%{route | event_name_prefix: "github."}, inbound_signal())
  end

  test "priority, specificity, and key order choose one DB route" do
    broad = route("broad", "chat", priority: 10, adapter: "feishu")
    specific = route("specific", "blackhole", priority: 10, adapter: "feishu", scope_id: "chat_a")
    earlier_key = route("alpha", "chat", priority: 10, adapter: "feishu", actor_id: "ou_a")
    lower = route("lower", "chat", priority: 1, adapter: "feishu", scope_id: "chat_a")

    assert {:ok, router} = Router.compile([broad, specific, earlier_key, lower])

    assert {:ok, %{source: :db_route, route: selected, target: target}} =
             Router.resolve(inbound_signal(), %{
               router: router,
               routes: Map.new([broad, specific, earlier_key, lower], &{&1.key, &1}),
               targets: %{
                 "chat" => target("chat", "agentic_chat_loop"),
                 "blackhole" => target("blackhole", "blackhole")
               }
             })

    assert selected.key == "alpha"
    assert target.key == "chat"
  end

  defp route(key, target_key, attrs) do
    attrs = Map.new(attrs)

    struct!(
      InboundRoute,
      Map.merge(
        %{
          key: key,
          name: key,
          priority: Map.get(attrs, :priority, 0),
          signal_pattern: "com.agentbull.x.inbound.**",
          target_key: target_key
        },
        attrs
      )
    )
  end

  defp target(key, kind),
    do: %Target{key: key, kind: kind, name: key, config: target_config(kind)}

  defp target_config("agentic_chat_loop") do
    %{
      "model" => "default",
      "system_prompt" => %{"soul" => "Test soul"},
      "agentic_chat_loop" => %{"max_iterations" => 4, "max_tokens" => 4096}
    }
  end

  defp target_config("blackhole"), do: %{}

  defp inbound_signal do
    Signal.new!(%{
      id: "sig-router",
      source: "bullx://gateway/feishu/default",
      type: "com.agentbull.x.inbound.received",
      data: %{
        "scope_id" => "chat_a",
        "thread_id" => "thread_a",
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
end
