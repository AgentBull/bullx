defmodule BullXAIAgent.Kind.AgenticChatLoop do
  @moduledoc """
  Runtime bridge from a BullX `agentic_chat_loop` target to AgenticLoop.

  This module is intentionally narrow: it builds the prompt/model/runtime config
  for one chat turn and returns an updated live `BullXAIAgent.Context`. Runtime
  owns Gateway signals, session processes, and deliveries.
  """

  alias BullX.Runtime.Targets.Target
  alias BullXAIAgent.Context, as: AIContext
  alias BullXAIAgent.LLM.Catalog
  alias BullXAIAgent.Reasoning.AgenticLoop
  alias BullXAIAgent.Reasoning.AgenticLoop.Config, as: AgenticLoopConfig
  alias BullXAIAgent.Reasoning.AgenticLoop.State, as: AgenticLoopState
  alias BullXAIAgent.Runtime.Event, as: RuntimeEvent

  @baseline_system_prompt """
  You are BullX, an AI assistant operating inside the BullX runtime. Follow operator instructions, preserve user privacy, and give direct, useful answers.
  """

  @aliases %{
    "default" => :default,
    "fast" => :fast,
    "heavy" => :heavy,
    "compression" => :compression
  }

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(
        %{target: %Target{} = target, context: %AIContext{} = context, user_text: user_text} =
          input,
        opts \\ []
      )
      when is_binary(user_text) do
    with {:ok, config} <- target_config(target),
         {:ok, system_prompt} <- system_prompt(config),
         {:ok, model} <- resolve_model(config["model"]),
         {:ok, runtime_config} <- runtime_config(config, model, system_prompt),
         {:ok, result} <- run_agentic_loop(input, context, system_prompt, runtime_config, opts),
         {:ok, answer} <- extract_answer(result) do
      refs = Map.get(input, :refs, %{})

      updated_context =
        context
        |> put_system_prompt(system_prompt)
        |> AIContext.append_user(user_text, refs: refs)
        |> AIContext.append_assistant(answer, nil, refs: refs)

      {:ok,
       %{
         answer: answer,
         context: updated_context,
         usage: Map.get(result, :usage, %{}),
         trace: Map.get(result, :trace, [])
       }}
    end
  rescue
    error -> {:error, error}
  end

  @spec baseline_system_prompt() :: String.t()
  def baseline_system_prompt, do: @baseline_system_prompt

  defp target_config(%Target{config: config}) when is_map(config), do: {:ok, config}
  defp target_config(_target), do: {:error, :invalid_target_config}

  defp system_prompt(%{"system_prompt" => %{"soul" => soul}}) when is_binary(soul) do
    case String.trim(soul) do
      "" -> {:error, {:invalid_target_config, :blank_soul}}
      soul -> {:ok, String.trim(@baseline_system_prompt) <> "\n\n" <> soul}
    end
  end

  defp system_prompt(_config), do: {:error, {:invalid_target_config, :missing_soul}}

  defp resolve_model(model) when is_binary(model) and is_map_key(@aliases, model),
    do: {:ok, Map.fetch!(@aliases, model)}

  defp resolve_model(model) when is_binary(model), do: Catalog.resolve_provider(model)
  defp resolve_model(_model), do: {:error, :invalid_model}

  defp runtime_config(config, model, system_prompt) do
    loop_config = Map.get(config, "agentic_chat_loop", %{})

    {:ok,
     AgenticLoopConfig.new(
       model: model,
       system_prompt: system_prompt,
       tools: %{},
       max_iterations: Map.get(loop_config, "max_iterations", 4),
       max_tokens: Map.get(loop_config, "max_tokens", 4_096),
       streaming: true
     )}
  end

  defp run_agentic_loop(
         input,
         %AIContext{} = context,
         system_prompt,
         %AgenticLoopConfig{} = config,
         opts
       ) do
    user_text = Map.fetch!(input, :user_text)
    refs = Map.get(input, :refs, %{})
    runner = Keyword.get(opts, :agentic_loop_module, AgenticLoop)

    state =
      user_text
      |> AgenticLoopState.new(system_prompt, request_id: request_id(refs))
      |> Map.put(:context, put_system_prompt(context, system_prompt))

    events =
      runner.stream_from_state(state, config,
        query: user_text,
        context: %{refs: refs}
      )
      |> maybe_emit_stream_deltas(opts)

    {:ok, collect_stream(runner, events)}
  end

  defp maybe_emit_stream_deltas(events, opts) do
    case Keyword.get(opts, :stream_delta_fun) do
      fun when is_function(fun, 1) ->
        Stream.map(events, fn event ->
          emit_stream_delta(event, fun)
          event
        end)

      _ ->
        events
    end
  end

  defp emit_stream_delta(%RuntimeEvent{kind: :llm_delta, data: data}, fun) when is_map(data) do
    maybe_emit_content_delta(data, fun)
  end

  defp emit_stream_delta(%{kind: :llm_delta, data: data}, fun) when is_map(data) do
    maybe_emit_content_delta(data, fun)
  end

  defp emit_stream_delta(_event, _fun), do: :ok

  defp maybe_emit_content_delta(data, fun) do
    chunk_type = Map.get(data, :chunk_type, Map.get(data, "chunk_type", :content))
    delta = Map.get(data, :delta, Map.get(data, "delta"))

    case {content_chunk?(chunk_type), delta} do
      {true, delta} when is_binary(delta) and delta != "" ->
        fun.(delta)

      _ ->
        :ok
    end
  end

  defp content_chunk?(chunk_type), do: chunk_type in [:content, "content"]

  defp collect_stream(runner, events) do
    case function_exported?(runner, :collect_stream, 1) do
      true -> runner.collect_stream(events)
      false -> AgenticLoop.collect_stream(events)
    end
  end

  defp extract_answer(%{result: answer}) when is_binary(answer) do
    case String.trim(answer) do
      "" -> {:error, :empty_answer}
      answer -> {:ok, answer}
    end
  end

  defp extract_answer(%{result: nil}), do: {:error, :empty_answer}
  defp extract_answer(%{result: answer}), do: {:ok, inspect(answer)}
  defp extract_answer(_result), do: {:error, :missing_answer}

  defp put_system_prompt(%AIContext{} = context, system_prompt),
    do: %{context | system_prompt: system_prompt}

  defp request_id(%{signal_id: signal_id}) when is_binary(signal_id), do: "runtime_#{signal_id}"

  defp request_id(%{"signal_id" => signal_id}) when is_binary(signal_id),
    do: "runtime_#{signal_id}"

  defp request_id(_refs), do: "runtime_#{Jido.Util.generate_id()}"
end
