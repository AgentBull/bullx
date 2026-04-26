defmodule BullXAIAgent.Reasoning.AlgorithmOfThoughts do
  @moduledoc """
  Canonical namespace entrypoint for Algorithm-of-Thoughts reasoning.

  This module exposes shared AoT helpers and points to the canonical strategy:
  `BullXAIAgent.Reasoning.AlgorithmOfThoughts.Strategy`.
  """

  alias BullXAIAgent.Reasoning.AlgorithmOfThoughts.Machine
  alias BullXAIAgent.Reasoning.AlgorithmOfThoughts.Strategy

  @doc "Returns the canonical AoT strategy module."
  @spec strategy_module() :: module()
  def strategy_module, do: Strategy

  @doc "Generates a unique AoT call id."
  @spec generate_call_id() :: String.t()
  defdelegate generate_call_id(), to: Machine

  @doc "Returns the default AoT system prompt for a given profile/search style."
  @spec default_system_prompt(Machine.profile(), Machine.search_style(), [String.t()]) ::
          String.t()
  defdelegate default_system_prompt(profile, search_style, examples \\ []), to: Machine
end
