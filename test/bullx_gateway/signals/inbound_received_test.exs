defmodule BullXGateway.Signals.InboundReceivedTest do
  use ExUnit.Case, async: true

  alias BullXGateway.Delivery.Content
  alias BullXGateway.Inputs.Action
  alias BullXGateway.Inputs.Message
  alias BullXGateway.Inputs.MessageEdited
  alias BullXGateway.Inputs.MessageRecalled
  alias BullXGateway.Inputs.Reaction
  alias BullXGateway.Inputs.SlashCommand
  alias BullXGateway.Inputs.Trigger
  alias BullXGateway.Signals.InboundReceived

  test "renders the canonical inbound carrier with string-key JSON-neutral maps" do
    input = %Trigger{
      id: "evt-trigger",
      source: "bullx://gateway/github/default",
      channel: {:github, "default"},
      scope_id: "bullx/example",
      thread_id: nil,
      actor: %{
        id: "system:market-feed",
        display: "Market Feed",
        bot: true,
        app_user_id: nil
      },
      agent_text: "A GitHub issue was opened",
      adapter_event: %{
        type: "github.issue.opened",
        version: 1,
        data: %{issue_number: 101}
      },
      refs: [],
      content: []
    }

    assert {:ok, signal} = InboundReceived.new(input)
    assert signal.type == "com.agentbull.x.inbound.received"
    assert signal.data["event_category"] == "trigger"
    assert signal.data["duplex"] == false

    assert signal.data["adapter_event"] == %{
             "type" => "github.issue.opened",
             "version" => 1,
             "data" => %{"issue_number" => 101}
           }

    assert signal.data["content"] == []
    assert signal.data["reply_channel"] == nil
    assert signal.extensions["bullx_channel_adapter"] == "github"
    assert signal.extensions["bullx_channel_tenant"] == "default"
  end

  test "rejects non-text content blocks that omit fallback_text" do
    input = %Message{
      id: "evt-message",
      source: "bullx://gateway/feishu/default",
      channel: {:feishu, "default"},
      scope_id: "chat_123",
      thread_id: nil,
      actor: %{
        id: "feishu:ou_123",
        display: "Alice",
        bot: false,
        app_user_id: nil
      },
      reply_channel: %{
        adapter: :feishu,
        tenant: "default",
        scope_id: "chat_123",
        thread_id: nil
      },
      agent_text: "sent an image",
      adapter_event: %{
        type: "feishu.message.image",
        version: 1,
        data: %{}
      },
      refs: [],
      content: [
        %Content{
          kind: :image,
          body: %{"url" => "https://cdn.example.com/image.png"}
        }
      ]
    }

    assert {:error, :missing_fallback_text} = InboundReceived.new(input)
  end

  describe "seven canonical categories" do
    test "Message renders duplex=true with reply_channel" do
      {:ok, signal} = InboundReceived.new(message_input())
      assert signal.data["event_category"] == "message"
      assert signal.data["duplex"] == true
      assert signal.data["agent_text"] == "hello"

      assert signal.data["reply_channel"] == %{
               "adapter" => "feishu",
               "tenant" => "default",
               "scope_id" => "oc_xxx",
               "thread_id" => nil
             }
    end

    test "MessageEdited carries target_external_message_id and duplex=true" do
      input =
        build_input(MessageEdited, %{
          target_external_message_id: "om_edit",
          agent_text: "updated text",
          edited_at: ~U[2026-04-21 10:02:00Z],
          adapter_event: %{type: "feishu.message.edited", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert signal.data["event_category"] == "message_edited"
      assert signal.data["duplex"] == true
      assert signal.data["target_external_message_id"] == "om_edit"
      assert signal.data["edited_at"] == "2026-04-21T10:02:00Z"
    end

    test "MessageRecalled default-renders agent_text from actor display" do
      input =
        build_input(MessageRecalled, %{
          target_external_message_id: "om_recall",
          recalled_at: ~U[2026-04-21 10:05:00Z],
          adapter_event: %{type: "feishu.message.recalled", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert signal.data["event_category"] == "message_recalled"
      assert signal.data["agent_text"] == "Boris recalled a message"
      assert signal.data["target_external_message_id"] == "om_recall"
    end

    test "Reaction default-renders agent_text when adapter omits it" do
      input =
        build_input(Reaction, %{
          target_external_message_id: "om_target",
          emoji: "THUMBSUP",
          action: :added,
          adapter_event: %{type: "feishu.reaction.created", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert signal.data["event_category"] == "reaction"
      assert signal.data["agent_text"] == "Boris reacted with THUMBSUP"
      assert signal.data["action"] == "added"
      assert signal.data["emoji"] == "THUMBSUP"
    end

    test "Action requires target/action_id/values and renders duplex=true" do
      input =
        build_input(Action, %{
          target_external_message_id: "om_card",
          action_id: "approve",
          values: %{"choice" => "approve"},
          adapter_event: %{type: "feishu.card.action_clicked", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert signal.data["event_category"] == "action"
      assert signal.data["duplex"] == true
      assert signal.data["action_id"] == "approve"
      assert signal.data["values"] == %{"choice" => "approve"}
    end

    test "SlashCommand synthesizes agent_text from command_name and args" do
      input =
        build_input(SlashCommand, %{
          command_name: "status",
          args: "detail",
          adapter_event: %{type: "feishu.command.issued", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert signal.data["event_category"] == "slash_command"
      assert signal.data["agent_text"] == "/status detail"
      assert signal.data["command_name"] == "status"
    end
  end

  describe "adapter_event validation" do
    test "rejects empty adapter_event.type" do
      input = %{message_input() | adapter_event: %{type: "", version: 1, data: %{}}}
      assert {:error, :invalid_adapter_event} = InboundReceived.new(input)
    end

    test "rejects non-integer adapter_event.version" do
      input = %{message_input() | adapter_event: %{type: "x.y", version: "1", data: %{}}}
      assert {:error, :invalid_adapter_event} = InboundReceived.new(input)
    end
  end

  defp message_input do
    build_input(Message, %{
      agent_text: "hello",
      content: [%Content{kind: :text, body: %{"text" => "hello"}}],
      adapter_event: %{type: "feishu.message.posted", version: 1, data: %{}}
    })
  end

  defp build_input(module, overrides) do
    struct!(module, Map.merge(shared_fields(), overrides))
  end

  defp shared_fields do
    %{
      id: "evt-#{System.unique_integer([:positive])}",
      source: "bullx://gateway/feishu/default",
      channel: {:feishu, "default"},
      scope_id: "oc_xxx",
      thread_id: nil,
      actor: %{
        id: "feishu:ou_boris",
        display: "Boris",
        bot: false,
        app_user_id: nil
      },
      reply_channel: %{
        adapter: :feishu,
        tenant: "default",
        scope_id: "oc_xxx",
        thread_id: nil
      },
      adapter_event: %{type: "feishu.placeholder", version: 1, data: %{}},
      refs: []
    }
  end
end
