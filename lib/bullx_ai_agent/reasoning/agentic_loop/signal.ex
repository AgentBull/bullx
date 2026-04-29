defmodule BullXAIAgent.Reasoning.AgenticLoop.Signal do
  @moduledoc """
  Signal envelope used by strategies/adapters to consume AgenticLoop runtime events.
  """

  use BullXAIAgent.Signal,
    type: "ai.agentic_loop.worker.event",
    default_source: "/ai/agentic_loop/worker",
    schema: [
      request_id: [type: :string, required: true, doc: "Request correlation ID"],
      event: [type: :map, required: true, doc: "AgenticLoop runtime event envelope"]
    ]
end
