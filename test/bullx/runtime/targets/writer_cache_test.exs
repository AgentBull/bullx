defmodule BullX.Runtime.Targets.WriterCacheTest do
  use BullX.DataCase, async: false

  alias BullX.Runtime.Targets
  alias BullX.Runtime.Targets.Cache
  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Target
  alias BullX.Runtime.Targets.Writer

  setup do
    allow_cache(Cache)
    Repo.delete_all(InboundRoute)
    Repo.delete_all(Target)
    Cache.refresh_all()
    on_exit(fn -> Cache.refresh_all() end)
    :ok
  end

  test "validates target kind and agentic_chat_loop config" do
    assert {:error, {:unsupported_target_kind, "workflow"}} =
             Writer.put_target(target_attrs(kind: "workflow"))

    assert {:error, {:invalid_main_kind, "blackhole"}} =
             Writer.put_target(target_attrs(key: "main", kind: "blackhole", config: %{}))

    assert {:error, {:blank_required_string, "soul"}} =
             Writer.put_target(
               target_attrs(config: put_in(agentic_config(), ["system_prompt", "soul"], " "))
             )

    assert {:ok, target} = Writer.put_target(target_attrs())
    assert target.config["agentic_chat_loop"]["max_iterations"] == 4
  end

  test "blackhole targets require empty config" do
    assert {:error, {:invalid_target_config, :blackhole_requires_empty_config}} =
             Writer.put_target(target_attrs(kind: "blackhole", config: %{"unexpected" => true}))

    assert {:ok, target} = Writer.put_target(target_attrs(kind: "blackhole", config: %{}))
    assert target.kind == "blackhole"
    assert target.config == %{}
  end

  test "route writes refresh cache and route deletes restore fallback" do
    assert {:ok, target} = Writer.put_target(target_attrs(key: "chat"))

    assert {:ok, route} =
             Writer.put_inbound_route(%{
               key: "feishu",
               name: "Feishu",
               priority: 50,
               adapter: "feishu",
               target_key: target.key
             })

    assert [^route] = Cache.list_inbound_routes()
    assert [%Target{key: "chat"}] = Cache.list_targets()

    assert {:ok, %{source: :db_route, route: %{key: "feishu"}, target: %{key: "chat"}}} =
             Targets.resolve(inbound_signal())

    assert :ok = Writer.delete_inbound_route("feishu")
    assert [] = Cache.list_inbound_routes()
    assert {:ok, %{source: :fallback, target: %{key: "main"}}} = Targets.resolve(inbound_signal())
  end

  test "event name and prefix are mutually exclusive" do
    assert {:ok, target} = Writer.put_target(target_attrs(key: "chat"))

    assert {:error, changeset} =
             Writer.put_inbound_route(%{
               key: "bad",
               name: "Bad",
               event_name: "feishu.message.created",
               event_name_prefix: "feishu.message.",
               target_key: target.key
             })

    assert "cannot be set when event_name is set" in errors_on(changeset).event_name_prefix
  end

  defp target_attrs(overrides \\ []) do
    %{
      key: "chat",
      kind: "agentic_chat_loop",
      name: "Chat",
      config: agentic_config()
    }
    |> Map.merge(Map.new(overrides))
  end

  defp agentic_config do
    %{
      "model" => "default",
      "system_prompt" => %{"soul" => "You are a test target."},
      "agentic_chat_loop" => %{"max_iterations" => 4, "max_tokens" => 4096}
    }
  end

  defp inbound_signal do
    Jido.Signal.new!(%{
      id: "sig-writer-cache",
      source: "bullx://gateway/feishu/default",
      type: "com.agentbull.x.inbound.received",
      data: %{
        "scope_id" => "chat_a",
        "thread_id" => nil,
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
