defmodule BullXAIAgent.Kind.AgenticChatLoopTest do
  use BullX.DataCase, async: false

  alias BullX.Runtime.Targets.Target
  alias BullXAIAgent.Context, as: AIContext
  alias BullXAIAgent.Kind.AgenticChatLoop
  alias BullXAIAgent.LLM.Catalog.Cache
  alias BullXAIAgent.LLM.Writer, as: LLMWriter
  alias BullXAIAgent.Reasoning.AgenticLoop.Config

  defmodule FakeRunner do
    use Agent

    def start_link(test_pid), do: Agent.start_link(fn -> test_pid end, name: __MODULE__)

    def stream_from_state(state, %Config{} = config, opts) do
      test_pid = Agent.get(__MODULE__, & &1)
      send(test_pid, {:agentic_loop_request, state.context, config, opts})
      [:done]
    end

    def collect_stream(_events) do
      %{result: "assistant answer", usage: %{"output_tokens" => 2}, trace: [:done]}
    end
  end

  defmodule FakeStreamingRunner do
    def stream_from_state(_state, %Config{}, _opts) do
      [
        %{kind: :llm_delta, data: %{chunk_type: :content, delta: "hello"}},
        %{kind: :llm_delta, data: %{chunk_type: :tool_call, delta: "tool-name"}},
        %{kind: :llm_delta, data: %{"chunk_type" => "content", "delta" => " world"}},
        %{kind: :request_completed, data: %{}}
      ]
    end

    def collect_stream(events) do
      _events = Enum.to_list(events)
      %{result: "streamed answer", usage: %{}, trace: []}
    end
  end

  setup do
    allow_cache(Cache)
    Cache.refresh_all()
    {:ok, _pid} = FakeRunner.start_link(self())

    on_exit(fn ->
      Cache.refresh_all()
      if Process.whereis(FakeRunner), do: Agent.stop(FakeRunner)
    end)

    :ok
  end

  test "builds prompt, resolves model alias, and returns updated live context" do
    assert {:ok, provider} = LLMWriter.put_provider(provider_attrs())
    assert {:ok, _binding} = LLMWriter.put_alias_binding(:default, {:provider, provider.name})

    context =
      AIContext.new()
      |> AIContext.append_user("prior")
      |> AIContext.append_assistant("previous answer")

    assert {:ok, result} =
             AgenticChatLoop.run(
               %{
                 target: target(),
                 context: context,
                 user_text: "next",
                 refs: %{signal_id: "sig-agentic", route_key: "route", target_key: "chat"}
               },
               agentic_loop_module: FakeRunner
             )

    assert result.answer == "assistant answer"
    assert result.usage == %{"output_tokens" => 2}

    assert_receive {:agentic_loop_request, request_context, %Config{} = config, opts}

    assert request_context.system_prompt =~
             AgenticChatLoop.baseline_system_prompt() |> String.trim()

    assert request_context.system_prompt =~ "Target soul"
    assert config.max_iterations == 3
    assert config.llm.max_tokens == 512
    assert Keyword.fetch!(opts, :query) == "next"

    assert [
             %{role: :system},
             %{role: :user, content: "prior"},
             %{role: :assistant, content: "previous answer"},
             %{role: :user, content: "next"},
             %{role: :assistant, content: "assistant answer"}
           ] = AIContext.to_messages(result.context)
  end

  test "emits only content deltas through the runtime stream callback" do
    assert {:ok, provider} = LLMWriter.put_provider(provider_attrs())
    assert {:ok, _binding} = LLMWriter.put_alias_binding(:default, {:provider, provider.name})

    assert {:ok, %{answer: "streamed answer"}} =
             AgenticChatLoop.run(
               %{
                 target: target(),
                 context: AIContext.new(),
                 user_text: "stream",
                 refs: %{signal_id: "sig-stream", route_key: "route", target_key: "chat"}
               },
               agentic_loop_module: FakeStreamingRunner,
               stream_delta_fun: fn delta -> send(self(), {:stream_delta, delta}) end
             )

    assert_receive {:stream_delta, "hello"}
    assert_receive {:stream_delta, " world"}
    refute_receive {:stream_delta, "tool-name"}, 100
  end

  defp target do
    %Target{
      key: "chat",
      kind: "agentic_chat_loop",
      name: "Chat",
      config: %{
        "model" => "default",
        "system_prompt" => %{"soul" => "Target soul"},
        "agentic_chat_loop" => %{"max_iterations" => 3, "max_tokens" => 512}
      }
    }
  end

  defp provider_attrs do
    %{
      name: "primary",
      provider_id: "openai",
      model_id: "gpt-4o-mini",
      base_url: "https://api.openai.com/v1",
      provider_options: %{}
    }
  end

  defp allow_cache(cache_module) do
    case Process.whereis(cache_module) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
