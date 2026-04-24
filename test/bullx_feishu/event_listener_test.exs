defmodule BullXFeishu.EventListenerTest do
  use ExUnit.Case, async: false

  alias BullXFeishu.{Cache, Channel, Config, EventListener}
  alias FeishuOpenAPI.Event

  defmodule GatewayStub do
    def deliver(delivery) do
      send(Process.get(:test_pid), {:delivery, delivery})
      {:ok, delivery.id}
    end
  end

  defmodule AccountsStub do
    def match_or_create_from_channel(_input), do: raise("direct commands bypass account gate")
  end

  setup do
    Process.put(:test_pid, self())

    {:ok, config} =
      Config.normalize({:feishu, "default"}, %{
        app_id: "cli_test",
        app_secret: "secret_test",
        gateway_module: GatewayStub,
        accounts_module: AccountsStub
      })

    {:ok, state: %Channel{channel: {:feishu, "default"}, config: config, cache: Cache.new()}}
  end

  test "direct command listener path returns {reply, state}", %{state: state} do
    event = message_event("/ping")

    assert {{:ok, %{delivery_id: delivery_id}}, %Channel{} = new_state} =
             EventListener.handle_event("im.message.receive_v1", event, state)

    assert new_state.cache != nil
    assert_receive {:delivery, delivery}
    assert delivery.id == delivery_id
  end

  defp message_event(text) do
    %Event{
      id: "evt_ping",
      type: "im.message.receive_v1",
      tenant_key: "tenant_1",
      app_id: "cli_test",
      raw: %{},
      content: %{
        "sender" => %{
          "sender_type" => "user",
          "sender_id" => %{"open_id" => "ou_user"},
          "name" => "Alice"
        },
        "message" => %{
          "message_id" => "om_1",
          "chat_id" => "oc_1",
          "chat_type" => "p2p",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => text})
        }
      }
    }
  end
end
