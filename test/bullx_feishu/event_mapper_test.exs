defmodule BullXFeishu.EventMapperTest do
  use ExUnit.Case, async: true

  alias BullXGateway.Inputs.{Message, SlashCommand}
  alias BullXFeishu.{Config, EventMapper}
  alias FeishuOpenAPI.Event

  setup do
    {:ok, config} =
      Config.normalize({:feishu, "default"}, %{
        app_id: "cli_test",
        app_secret: "secret_test",
        bot_open_id: "ou_bot"
      })

    {:ok, config: config}
  end

  test "maps a Feishu message receive event to a Gateway message", %{config: config} do
    event = message_event("hello")

    assert {:ok, %{input: %Message{} = input, account_input: account_input}} =
             EventMapper.map_event("im.message.receive_v1", event, config)

    assert input.id == "evt_1"
    assert input.channel == {:feishu, "default"}
    assert input.scope_id == "oc_1"
    assert input.actor.id == "feishu:ou_user"
    assert account_input.external_id == "feishu:ou_user"
    assert hd(input.content).body["text"] == "hello"
  end

  test "maps non-local slash commands to Gateway slash command inputs", %{config: config} do
    event = message_event("/deploy production")

    assert {:ok, %{input: %SlashCommand{} = input}} =
             EventMapper.map_event("im.message.receive_v1", event, config)

    assert input.command_name == "deploy"
    assert input.args == "production"
  end

  test "returns direct command for /ping before account gating", %{config: config} do
    event = message_event("/ping")

    assert {:direct_command, command} =
             EventMapper.map_event("im.message.receive_v1", event, config)

    assert command.name == "ping"
    assert command.chat_id == "oc_1"
    assert command.actor.id == "feishu:ou_user"
  end

  test "ignores configured self-sent bot messages", %{config: config} do
    event =
      message_event("bot echo")
      |> put_in([Access.key!(:content), "sender", "sender_type"], "bot")
      |> put_in([Access.key!(:content), "sender", "sender_id", "open_id"], "ou_bot")

    assert {:ignore, :self_sent_bot_message} =
             EventMapper.map_event("im.message.receive_v1", event, config)
  end

  defp message_event(text) do
    %Event{
      id: "evt_1",
      type: "im.message.receive_v1",
      tenant_key: "tenant_1",
      app_id: "cli_test",
      raw: %{},
      content: %{
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
