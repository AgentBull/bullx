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
        bot: true
      },
      content: [%Content{kind: :text, body: %{"text" => "A GitHub issue was opened"}}],
      event: %{
        name: "github.issue.opened",
        version: 1,
        data: %{issue_number: 101}
      },
      refs: []
    }

    assert {:ok, signal} = InboundReceived.new(input)
    assert signal.type == "com.agentbull.x.inbound.received"
    assert get_in(signal.data, ["event", "type"]) == "trigger"
    assert signal.data["duplex"] == false

    assert signal.data["event"] == %{
             "type" => "trigger",
             "name" => "github.issue.opened",
             "version" => 1,
             "data" => %{"issue_number" => 101}
           }

    assert signal.data["content"] == [
             %{"kind" => "text", "body" => %{"text" => "A GitHub issue was opened"}}
           ]

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
        bot: false
      },
      reply_channel: %{
        adapter: :feishu,
        tenant: "default",
        scope_id: "chat_123",
        thread_id: nil
      },
      event: %{
        name: "feishu.message.image",
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

  describe "seven canonical event types" do
    test "Message renders duplex=true with reply_channel" do
      {:ok, signal} = InboundReceived.new(message_input())
      assert get_in(signal.data, ["event", "type"]) == "message"
      assert signal.data["duplex"] == true

      assert signal.data["content"] == [
               %{"kind" => "text", "body" => %{"text" => "hello"}}
             ]

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
          edited_at: ~U[2026-04-21 10:02:00Z],
          content: [%Content{kind: :text, body: %{"text" => "updated text"}}],
          event: %{name: "feishu.message.edited", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert get_in(signal.data, ["event", "type"]) == "message_edited"
      assert signal.data["duplex"] == true
      assert signal.data["target_external_message_id"] == "om_edit"
      assert signal.data["edited_at"] == "2026-04-21T10:02:00Z"
    end

    test "MessageRecalled default-renders content from actor display" do
      input =
        build_input(MessageRecalled, %{
          target_external_message_id: "om_recall",
          recalled_at: ~U[2026-04-21 10:05:00Z],
          event: %{name: "feishu.message.recalled", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert get_in(signal.data, ["event", "type"]) == "message_recalled"

      assert signal.data["content"] == [
               %{"kind" => "text", "body" => %{"text" => "Boris recalled a message"}}
             ]

      assert signal.data["target_external_message_id"] == "om_recall"
    end

    test "Reaction default-renders content when adapter omits it" do
      input =
        build_input(Reaction, %{
          target_external_message_id: "om_target",
          emoji: "THUMBSUP",
          action: :added,
          event: %{name: "feishu.reaction.created", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert get_in(signal.data, ["event", "type"]) == "reaction"

      assert signal.data["content"] == [
               %{"kind" => "text", "body" => %{"text" => "Boris reacted with THUMBSUP"}}
             ]

      assert signal.data["action"] == "added"
      assert signal.data["emoji"] == "THUMBSUP"
    end

    test "Action requires target/action_id/values and renders duplex=true" do
      input =
        build_input(Action, %{
          target_external_message_id: "om_card",
          action_id: "approve",
          values: %{"choice" => "approve"},
          event: %{name: "feishu.card.action_clicked", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert get_in(signal.data, ["event", "type"]) == "action"
      assert signal.data["duplex"] == true
      assert signal.data["action_id"] == "approve"
      assert signal.data["values"] == %{"choice" => "approve"}

      assert signal.data["content"] == [
               %{"kind" => "text", "body" => %{"text" => "Boris submitted action: approve"}}
             ]
    end

    test "MessageRecalled default content uses recalled_by_actor when present" do
      input =
        build_input(MessageRecalled, %{
          target_external_message_id: "om_recall",
          recalled_at: ~U[2026-04-21 10:05:00Z],
          recalled_by_actor: %{
            id: "feishu:ou_admin",
            display: "Admin",
            bot: false
          },
          event: %{name: "feishu.message.recalled", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)

      assert signal.data["content"] == [
               %{"kind" => "text", "body" => %{"text" => "Admin recalled a message"}}
             ]
    end

    test "SlashCommand synthesizes content from command_name and args" do
      input =
        build_input(SlashCommand, %{
          command_name: "status",
          args: "detail",
          event: %{name: "feishu.command.issued", version: 1, data: %{}}
        })

      {:ok, signal} = InboundReceived.new(input)
      assert get_in(signal.data, ["event", "type"]) == "slash_command"

      assert signal.data["content"] == [
               %{"kind" => "text", "body" => %{"text" => "/status detail"}}
             ]

      assert signal.data["command_name"] == "status"
    end
  end

  describe "event validation" do
    test "rejects empty event.name" do
      input = %{message_input() | event: %{name: "", version: 1, data: %{}}}
      assert {:error, :invalid_event} = InboundReceived.new(input)
    end

    test "rejects non-integer event.version" do
      input = %{message_input() | event: %{name: "x.y", version: "1", data: %{}}}
      assert {:error, :invalid_event} = InboundReceived.new(input)
    end
  end

  describe "content invariant" do
    test "rejects Message with empty content" do
      input = %{message_input() | content: []}
      assert {:error, :invalid_content} = InboundReceived.new(input)
    end

    test "rejects Trigger without content (no default synthesis)" do
      input = %Trigger{
        id: "evt-trigger-empty",
        source: "bullx://gateway/github/default",
        channel: {:github, "default"},
        scope_id: "bullx/example",
        thread_id: nil,
        actor: %{
          id: "system:market-feed",
          display: "Market Feed",
          bot: true
        },
        event: %{name: "github.issue.opened", version: 1, data: %{}},
        content: [],
        refs: []
      }

      assert {:error, :invalid_content} = InboundReceived.new(input)
    end
  end

  describe "actor invariant" do
    test "rejects actor with empty display" do
      input = %{
        message_input()
        | actor: %{id: "feishu:ou_boris", display: "", bot: false}
      }

      assert {:error, :missing_actor_display} = InboundReceived.new(input)
    end
  end

  defp message_input do
    build_input(Message, %{
      content: [%Content{kind: :text, body: %{"text" => "hello"}}],
      event: %{name: "feishu.message.posted", version: 1, data: %{}}
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
        bot: false
      },
      reply_channel: %{
        adapter: :feishu,
        tenant: "default",
        scope_id: "oc_xxx",
        thread_id: nil
      },
      event: %{name: "feishu.placeholder", version: 1, data: %{}},
      refs: [],
      content: []
    }
  end
end
