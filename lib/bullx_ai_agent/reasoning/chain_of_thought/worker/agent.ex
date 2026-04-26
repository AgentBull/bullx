defmodule BullXAIAgent.Reasoning.ChainOfThought.Worker.Agent do
  @moduledoc false

  use Jido.Agent,
    name: "cot_worker_agent",
    description: "Internal delegated CoT runtime worker",
    default_plugins: false,
    plugins: [],
    strategy: {BullXAIAgent.Reasoning.ChainOfThought.Worker.Strategy, []},
    schema:
      Zoi.object(%{
        __strategy__: Zoi.map() |> Zoi.default(%{})
      })
end
