defmodule BullX.Runtime.Targets.SessionTest do
  use ExUnit.Case, async: false

  alias BullX.Runtime.Targets.InboundRoute
  alias BullX.Runtime.Targets.Session
  alias BullX.Runtime.Targets.Target
  alias BullXAIAgent.Context, as: AIContext
  alias BullXGateway.Delivery
  alias Jido.Signal

  defmodule FakeKind do
    def run(%{context: %AIContext{} = context, user_text: user_text}, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:kind_turn, AIContext.to_messages(context), user_text}
      )

      answer = "answer: #{user_text}"

      updated_context =
        context
        |> AIContext.append_user(user_text)
        |> AIContext.append_assistant(answer)

      {:ok, %{answer: answer, context: updated_context, usage: %{}, trace: []}}
    end
  end

  defmodule FakeGateway do
    use Agent

    def start_link(test_pid), do: Agent.start_link(fn -> test_pid end, name: __MODULE__)

    def deliver(%Delivery{} = delivery) do
      test_pid = Agent.get(__MODULE__, & &1)
      send(test_pid, {:delivered, delivery})
      {:ok, delivery.id}
    end
  end

  setup do
    {:ok, _pid} = FakeGateway.start_link(self())
    on_exit(fn -> stop_fake_gateway() end)
    :ok
  end

  test "serializes turns and carries live context into the next turn" do
    {:ok, session} = Session.start_link(session_key: {:session_test, System.unique_integer()})
    resolution = resolution()

    assert {:ok, %{answer: "answer: first"}} =
             Session.turn(session, resolution, signal("sig-1", "first"),
               kind_module: FakeKind,
               gateway_module: FakeGateway,
               test_pid: self()
             )

    assert_receive {:kind_turn, [], "first"}
    assert_receive {:delivered, first_delivery}
    assert first_delivery.content.body["text"] == "answer: first"

    assert {:ok, %{answer: "answer: second"}} =
             Session.turn(session, resolution, signal("sig-2", "second"),
               kind_module: FakeKind,
               gateway_module: FakeGateway,
               test_pid: self()
             )

    assert_receive {:kind_turn,
                    [
                      %{role: :user, content: "first"},
                      %{role: :assistant, content: "answer: first"}
                    ], "second"}
  end

  test "non-duplex signals skip reply delivery" do
    {:ok, session} = Session.start_link(session_key: {:session_test, System.unique_integer()})

    assert {:ok, %{skipped: :not_duplex}} =
             Session.turn(session, resolution(), non_duplex_signal(),
               kind_module: FakeKind,
               gateway_module: FakeGateway,
               test_pid: self()
             )

    refute_receive {:delivered, _delivery}, 100
  end

  test "idle timeout stops inactive sessions" do
    {:ok, session} =
      Session.start_link(
        session_key: {:session_timeout_test, System.unique_integer()},
        idle_timeout_ms: 20
      )

    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 200
  end

  test "ignores stale runner DOWN messages after a turn" do
    {:ok, session} =
      Session.start_link(session_key: {:session_down_test, System.unique_integer()})

    send(session, {:DOWN, make_ref(), :process, self(), :normal})

    assert :sys.get_state(session)
  end

  defp resolution do
    %{
      source: :db_route,
      route: %InboundRoute{key: "route"},
      target: %Target{
        key: "chat",
        kind: "agentic_chat_loop",
        name: "Chat",
        config: %{}
      }
    }
  end

  defp signal(id, text) do
    Signal.new!(%{
      id: id,
      source: "bullx://gateway/session_test/default",
      type: "com.agentbull.x.inbound.received",
      data: %{
        "duplex" => true,
        "scope_id" => "scope",
        "thread_id" => nil,
        "reply_to_external_id" => "om_1",
        "reply_channel" => %{
          "adapter" => "session_test",
          "channel_id" => "default",
          "scope_id" => "scope",
          "thread_id" => nil
        },
        "event" => %{"type" => "message", "name" => "test.message"},
        "actor" => %{"id" => "actor"},
        "content" => [%{"kind" => "text", "body" => %{"text" => text}}]
      },
      extensions: %{
        "bullx_channel_adapter" => "session_test",
        "bullx_channel_id" => "default"
      }
    })
  end

  defp non_duplex_signal do
    signal("sig-non-duplex", "ignored")
    |> Map.update!(:data, &Map.merge(&1, %{"duplex" => false, "reply_channel" => nil}))
  end

  defp stop_fake_gateway do
    case Process.whereis(FakeGateway) do
      nil ->
        :ok

      pid ->
        Agent.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
