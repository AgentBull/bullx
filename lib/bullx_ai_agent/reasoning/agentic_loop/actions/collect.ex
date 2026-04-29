defmodule BullXAIAgent.Reasoning.AgenticLoop.Actions.Collect do
  @moduledoc """
  Collect a terminal result from AgenticLoop events.
  """

  use Jido.Action,
    name: "agentic_loop_collect",
    description: "Collect terminal output from AgenticLoop runtime events",
    category: "ai",
    tags: ["agentic_loop", "runtime", "collect"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        events: Zoi.any() |> Zoi.optional(),
        model: Zoi.any() |> Zoi.optional(),
        system_prompt: Zoi.string() |> Zoi.optional(),
        tools: Zoi.any() |> Zoi.optional(),
        allowed_tools: Zoi.list(Zoi.string()) |> Zoi.optional(),
        request_transformer: Zoi.atom() |> Zoi.optional(),
        max_iterations: Zoi.integer() |> Zoi.default(10),
        max_tokens: Zoi.integer() |> Zoi.default(4096),
        temperature: Zoi.float() |> Zoi.default(0.2),
        llm_opts: Zoi.any() |> Zoi.optional(),
        llm_timeout_ms: Zoi.integer() |> Zoi.optional(),
        req_http_options: Zoi.list(Zoi.any()) |> Zoi.optional(),
        stream_receive_timeout_ms: Zoi.integer() |> Zoi.optional(),
        stream_timeout_ms: Zoi.integer() |> Zoi.optional(),
        tool_timeout_ms: Zoi.integer() |> Zoi.default(15_000),
        tool_max_retries: Zoi.integer() |> Zoi.default(1),
        tool_retry_backoff_ms: Zoi.integer() |> Zoi.default(200),
        tool_concurrency: Zoi.integer() |> Zoi.default(4),
        task_supervisor: Zoi.any() |> Zoi.optional(),
        runtime_context: Zoi.map() |> Zoi.optional()
      })

  alias BullXAIAgent.Reasoning.AgenticLoop.Actions.Helpers
  alias BullXAIAgent.Reasoning.AgenticLoop

  @impl Jido.Action
  def run(params, context) do
    config = Helpers.build_config(params, context)

    case params[:events] do
      events when not is_nil(events) ->
        AgenticLoop.collect(events, config, [])

      _ ->
        {:error, :events_required}
    end
  end
end
