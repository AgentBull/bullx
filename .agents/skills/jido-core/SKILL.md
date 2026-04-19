---
name: jido-core
description: >-
  Jido ecosystem overview, conventions, and foundational patterns.
  Load this skill when working with any Jido package. Covers the
  ecosystem map, Elixir/OTP conventions, project structure, and
  core design principles. Use when asked about Jido, building agents,
  or working in a Jido-based project.
metadata:
  author: agentjido
  version: "0.1.0"
license: Apache-2.0
compatibility: Requires Elixir 1.17+ and Erlang/OTP 26+
---

# Jido Core

Foundational skill for the Jido agent framework ecosystem.

## Jido Ecosystem

| Package | Purpose | Key macro/module |
|---------|---------|-----------------|
| **jido** (core) | Agent framework | `use Jido.Agent`, `cmd/2`, directives, plugins, `AgentServer` |
| **jido_action** | Composable validated actions | `use Jido.Action`, schema, `run/2` |
| **jido_signal** | CloudEvents-based signals and routing | `Jido.Signal`, `Jido.Signal.Router` |
| **jido_ai** | AI/LLM integration for agents | `Jido.AI`, tool-calling, prompt chains |
| **req_llm** | HTTP client for LLM APIs | Anthropic, OpenAI, Google, Ollama |

## Core Design Principles

1. **Agents are immutable data structures** — plain structs, no hidden state.
2. **`cmd/2` is the single entry point** — actions in → updated agent + directives out.
3. **State changes are pure data transformations** — actions receive params, return maps.
4. **Side effects are directives** — typed descriptions executed by the runtime, never inline.
5. **Built on OTP** — agents run as GenServer processes (`AgentServer`) in production.

## Project Structure Convention

```
my_app/
├── lib/my_app/
│   ├── agents/          # Agent modules (use Jido.Agent)
│   ├── actions/         # Action modules (use Jido.Action)
│   ├── plugins/         # Plugin modules extending agents
│   └── sensors/         # Sensor modules for external input
├── test/
├── config/
├── mix.exs
└── AGENTS.md
```

## Elixir/OTP Conventions for Jido

- Always `use Jido.Agent` with `name`, `description`, and `schema`.
- Define `signal_routes` for runtime signal handling in `AgentServer`.
- Keep actions pure — side effects belong in directives.
- Use NimbleOptions schemas for all validation.
- Follow standard Elixir naming: `PascalCase` modules, `snake_case` functions.
- Run `mix test` and `mix quality` before committing.
- Prefer `@moduledoc` and `@doc` on all public modules and functions.

## Key Types

| Type | Description |
|------|-------------|
| `Jido.Agent.t()` | The agent struct — immutable, holds state and metadata |
| `Jido.Instruction.t()` | Action + params tuple passed to `cmd/2` |
| `Jido.Signal.t()` | CloudEvents envelope carrying event data |

### Directive Types

| Directive | Effect |
|-----------|--------|
| `Emit` | Dispatch a signal to the bus |
| `Spawn` | Spawn a BEAM child process |
| `SpawnAgent` | Spawn a child Jido agent |
| `StopChild` | Stop a tracked child process |
| `Schedule` | Send a delayed message |
| `Stop` | Stop the agent process |

## Quick Example

```elixir
defmodule MyApp.Agents.Counter do
  use Jido.Agent,
    name: "counter",
    description: "A simple counter agent",
    schema: [
      count: [type: :integer, default: 0]
    ],
    actions: [MyApp.Actions.Increment]

  signal_routes do
    on "counter.increment", do: act(MyApp.Actions.Increment)
  end
end

defmodule MyApp.Actions.Increment do
  use Jido.Action,
    name: "increment",
    description: "Increment the counter by a given amount",
    schema: [
      amount: [type: :integer, default: 1]
    ]

  @impl true
  def run(params, context) do
    current = context.state.count
    {:ok, %{count: current + params.amount}}
  end
end

# Usage
{:ok, agent} = Counter.new()
{agent, directives} = Counter.cmd(agent, {Increment, %{amount: 5}})
agent.state.count
#=> 5
```

## Available Reference Docs

For deeper information, read these files:

- `reference/agents.md` — Agent definition, schema, `cmd/2`, plugins, `AgentServer`
- `reference/actions.md` — Action behaviour, `run/2`, schema validation, composition
- `reference/directives.md` — Directive types, runtime processing, custom directives

## Workflow

When working in a Jido project:

1. **Identify the package** — which Jido library is involved?
2. **Check the agent** — read the agent module for schema and actions.
3. **Trace through `cmd/2`** — follow action → state update → directives.
4. **Run tests** — `mix test` for correctness, `mix quality` for lint/format/dialyzer.
5. **Load deeper skills** — load package-specific skills (jido-actions, jido-signals, jido-ai) as needed.
