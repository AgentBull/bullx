defmodule BullXAIAgent.Reasoning.AgenticLoop.Worker.Agent do
  @moduledoc false

  use Jido.Agent,
    name: "agentic_loop_worker_agent",
    description: "Internal delegated AgenticLoop runtime worker",
    default_plugins: false,
    plugins: [],
    strategy: {BullXAIAgent.Reasoning.AgenticLoop.Worker.Strategy, []},
    schema:
      Zoi.object(%{
        __strategy__: Zoi.map() |> Zoi.default(%{})
      })
end
