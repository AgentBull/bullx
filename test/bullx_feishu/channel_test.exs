defmodule BullXFeishu.ChannelTest do
  use ExUnit.Case, async: false

  alias BullXFeishu.{Channel, Config}
  alias FeishuOpenAPI.Event.Dispatcher

  defmodule GatewayStub do
    @pid_key {__MODULE__, :test_pid}

    def put_test_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear_test_pid, do: :persistent_term.erase(@pid_key)

    def deliver(delivery) do
      send(:persistent_term.get(@pid_key), {:delivery, delivery})
      {:ok, delivery.id}
    end
  end

  defmodule AccountsStub do
    def match_or_create_from_channel(_input), do: raise("direct commands bypass account gate")
  end

  setup do
    GatewayStub.put_test_pid(self())
    on_exit(&GatewayStub.clear_test_pid/0)

    channel = {:feishu, "channel-#{System.unique_integer([:positive])}"}

    {:ok, config} =
      Config.normalize(channel, %{
        app_id: "cli_test",
        app_secret: "secret_test",
        gateway_module: GatewayStub,
        accounts_module: AccountsStub
      })

    start_supervised!({Channel, {channel, config}})

    {:ok, channel: channel, config: config}
  end

  test "event_dispatcher routes message receive events into the BullX channel", %{
    channel: channel,
    config: config
  } do
    dispatcher = Channel.event_dispatcher(channel, config)

    assert {:ok, {:ok, %{delivery_id: delivery_id}}} =
             Dispatcher.dispatch(dispatcher, {:decoded, message_event("/ping")})

    assert_receive {:delivery, delivery}
    assert delivery.id == delivery_id
    assert delivery.content.body["text"] == "PONG!"
  end

  defp message_event(text) do
    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => "evt_dispatcher_ping",
        "event_type" => "im.message.receive_v1",
        "tenant_key" => "tenant_1",
        "app_id" => "cli_test"
      },
      "event" => %{
        "sender" => %{
          "sender_type" => "user",
          "sender_id" => %{"open_id" => "ou_user", "user_id" => "u_user"},
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
