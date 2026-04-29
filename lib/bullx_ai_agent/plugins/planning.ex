require BullXAIAgent.Actions.Planning.Decompose
# Ensure actions are compiled before the plugin
require BullXAIAgent.Actions.Planning.Plan
require BullXAIAgent.Actions.Planning.Prioritize

defmodule BullXAIAgent.Plugins.Planning do
  @moduledoc """
  A Jido.Plugin providing AI-powered planning capabilities.

  This plugin exposes three planning actions:

  * `Plan` - Generate structured plans from goals with constraints and resources
  * `Decompose` - Break down complex goals into hierarchical sub-goals
  * `Prioritize` - Order tasks by priority based on given criteria

  ## Signal Contracts

  - `planning.plan` -> `BullXAIAgent.Actions.Planning.Plan`
  - `planning.decompose` -> `BullXAIAgent.Actions.Planning.Decompose`
  - `planning.prioritize` -> `BullXAIAgent.Actions.Planning.Prioritize`

  ## Mount State Defaults

  `mount/2` initializes shared defaults consumed by planning actions when caller
  params omit those fields:

  - `default_model`: `:heavy`
  - `default_max_tokens`: `4096`
  - `default_temperature`: `0.7`

  Action-specific inputs remain action-owned:

  - `Plan`: `goal` + optional `constraints`, `resources`, `max_steps`
  - `Decompose`: `goal` + optional `max_depth`, `context`
  - `Prioritize`: `tasks` + optional `criteria`, `context`

  ## Usage

  Attach to an agent:

      defmodule MyAgent do
        use Jido.Agent,

        plugins: [
          {BullXAIAgent.Plugins.Planning, []}
        ]
      end

  Or use the action directly:

      Jido.Exec.run(BullXAIAgent.Actions.Planning.Plan, %{
        goal: "Build a web application",
        constraints: ["Must use Elixir", "Budget limited"],
        resources: ["2 developers", "3 months"]
      })

  ## Model Resolution

  The plugin uses `BullXAIAgent.resolve_model/1` to resolve model aliases:

  * `:fast` - Quick model for simple tasks
  * `:fast` - Quick model for simple tasks
  * `:heavy` - Heavier model for complex planning tasks

  ## Architecture Notes

  **Generation Facade**: Planning actions call through `BullXAIAgent`.
  **Specialized Prompts**: Each action uses a task-specific system prompt.
  **Lightweight State**: Plugin state only stores execution defaults.
  """

  use Jido.Plugin,
    name: "planning",
    state_key: :planner,
    actions: [
      BullXAIAgent.Actions.Planning.Plan,
      BullXAIAgent.Actions.Planning.Decompose,
      BullXAIAgent.Actions.Planning.Prioritize
    ],
    description: "Provides AI-powered planning, goal decomposition, and task prioritization",
    category: "ai",
    tags: ["planning", "decomposition", "prioritization", "ai"],
    vsn: "1.0.0"

  @doc """
  Initialize plugin state when mounted to an agent.

  Returns initial state with any configured defaults.
  """
  @impl Jido.Plugin
  def mount(_agent, config) do
    initial_state = %{
      default_model: Map.get(config, :default_model, :heavy),
      default_max_tokens: Map.get(config, :default_max_tokens, 4096),
      default_temperature: Map.get(config, :default_temperature, 0.7)
    }

    {:ok, initial_state}
  end

  @doc """
  Returns the schema for plugin state.

  Defines the structure and defaults for Planning plugin state.
  """
  def schema do
    Zoi.object(%{
      default_model:
        Zoi.atom(description: "Default model alias (:default, :fast, :heavy, :compression)")
        |> Zoi.default(:heavy),
      default_max_tokens:
        Zoi.integer(description: "Default max tokens for generation") |> Zoi.default(4096),
      default_temperature:
        Zoi.float(description: "Default sampling temperature (0.0-2.0)")
        |> Zoi.default(0.7)
    })
  end

  @doc """
  Returns the signal router for this plugin.

  Maps signal patterns to action modules.
  """
  @impl Jido.Plugin
  def signal_routes(_config) do
    [
      {"planning.plan", BullXAIAgent.Actions.Planning.Plan},
      {"planning.decompose", BullXAIAgent.Actions.Planning.Decompose},
      {"planning.prioritize", BullXAIAgent.Actions.Planning.Prioritize}
    ]
  end

  @doc """
  Pre-routing hook for incoming signals.

  Currently returns :continue to allow normal routing.
  """
  @impl Jido.Plugin
  def handle_signal(_signal, _context) do
    {:ok, :continue}
  end

  @doc """
  Transform the result returned from action execution.

  Currently passes through results unchanged.
  """
  @impl Jido.Plugin
  def transform_result(_action, result, _context) do
    result
  end

  @doc """
  Returns signal patterns this plugin responds to.
  """
  def signal_patterns do
    [
      "planning.plan",
      "planning.decompose",
      "planning.prioritize"
    ]
  end
end
