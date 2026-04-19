---
name: jido-agent
description: >-
  Build Jido Agents with schema validation, cmd/2 command pattern,
  plugins, and directives. Use when creating new agents, defining
  agent schemas, adding plugins, or working with the AgentServer runtime.
metadata:
  author: agentjido
  version: "0.1.0"
license: Apache-2.0
---

# Building Jido Agents

## MANDATORY PREPARATION

Invoke $jido-core first — it contains ecosystem context,
conventions, and core design principles. Follow its guidance before proceeding.

## Overview

A Jido Agent is an **immutable data structure** that holds state and processes
commands via `cmd/2`. Agents are pure functions — no GenServer, no side effects.
The OTP runtime (`AgentServer`) is a separate concern.

Core API:
- `new/1` — create a new agent
- `set/2` — update state directly
- `validate/2` — validate state against schema
- `cmd/2` — execute actions: `(agent, action) -> {agent, directives}`

---

## Step 1: Define the Agent Module

```elixir
defmodule MyApp.TaskManager do
  use Jido.Agent,
    name: "task_manager",
    description: "Manages a list of tasks with priorities",
    schema: [
      tasks: [type: {:list, :any}, default: []],
      status: [type: :atom, default: :idle],
      task_count: [type: :integer, default: 0]
    ]

  def signal_routes(_ctx) do
    [
      {"task.add", MyApp.Actions.AddTask},
      {"task.complete", MyApp.Actions.CompleteTask},
      {"task.list", MyApp.Actions.ListTasks}
    ]
  end
end
```

### Required Options

| Option        | Type            | Description                          |
|---------------|-----------------|--------------------------------------|
| `name`        | `String.t()`   | Snake_case identifier                |
| `description` | `String.t()`   | What the agent does                  |
| `schema`      | `keyword()`     | NimbleOptions or Zoi state schema    |

### Optional Options

| Option           | Type        | Description                                 |
|------------------|-------------|---------------------------------------------|
| `strategy`       | module/tuple| Execution strategy (default: `Strategy.Direct`) |
| `plugins`        | list        | Plugin modules or `{module, config}` tuples |
| `signal_routes`  | list        | Compile-time signal-to-action route table   |
| `schedules`      | list        | Cron schedules as `{expr, signal_type}`     |

---

## Step 2: Configure Schema

Use NimbleOptions (legacy) or Zoi (recommended for new code):

```elixir
# NimbleOptions
schema: [
  status: [type: :atom, default: :idle],
  counter: [type: :integer, default: 0]
]

# Zoi (recommended)
schema: Zoi.object(%{
  status: Zoi.atom() |> Zoi.default(:idle),
  counter: Zoi.integer() |> Zoi.default(0)
})
```

Both are handled transparently by the Agent module.

---

## Step 3: Define Signal Routes

Signal routes map incoming signal types to action modules. AgentServer uses
these to dispatch signals to `cmd/2`.

```elixir
def signal_routes(_ctx) do
  [
    {"user.created", HandleUserCreated},           # simple mapping
    {"counter.increment", IncrementAction, 10},    # with priority
    {"payment.*", LargePaymentAction},             # wildcard
    {"order.placed", {ProcessOrder, %{notify: true}}}  # with static params
  ]
end
```

Route formats:
- `{path, ActionModule}` — priority 0
- `{path, ActionModule, priority}` — explicit priority
- `{path, {ActionModule, %{params}}}` — with static params
- `{path, guard_fn, ActionModule, priority}` — with guard function

---

## Step 4: Implement cmd/2 Workflow

`cmd/2` is the core operation. It accepts actions and returns `{agent, directives}`.

```elixir
# Single action
{agent, directives} = MyApp.TaskManager.cmd(agent, MyApp.Actions.AddTask)

# Action with params
{agent, directives} = MyApp.TaskManager.cmd(agent, {MyApp.Actions.AddTask, %{title: "Write docs"}})

# List of actions (processed sequentially)
{agent, directives} = MyApp.TaskManager.cmd(agent, [
  {MyApp.Actions.AddTask, %{title: "Task 1"}},
  {MyApp.Actions.AddTask, %{title: "Task 2"}}
])
```

Key invariants:
- The returned `agent` is **always complete** — no "apply directives" step
- `directives` are **external effects only** — they never modify agent state
- `cmd/2` is a **pure function** — same inputs, same outputs

---

## Step 5: Understand Directives

Directives describe effects for the runtime to interpret. They are bare structs:

| Directive                    | Purpose                                |
|------------------------------|----------------------------------------|
| `%Directive.Emit{}`         | Dispatch a signal via Signal.Dispatch  |
| `%Directive.Error{}`        | Signal an error                        |
| `%Directive.Spawn{}`        | Spawn a child process                  |
| `%Directive.Schedule{}`     | Schedule a delayed message             |
| `%Directive.RunInstruction{}`| Execute instruction at runtime        |
| `%Directive.Stop{}`         | Stop the agent process                 |

Emit with dispatch targets:

```elixir
%Directive.Emit{signal: my_signal}                           # default
%Directive.Emit{signal: my_signal, dispatch: {:pubsub, topic: "events"}}
%Directive.Emit{signal: my_signal, dispatch: {:pid, target: pid}}
```

---

## Step 6: Add Plugins

Plugins provide reusable capabilities with isolated state:

```elixir
defmodule MyApp.TaskManager do
  use Jido.Agent,
    name: "task_manager",
    plugins: [
      MyApp.Plugins.AuditLog,
      {MyApp.Plugins.RateLimit, %{max_per_minute: 100}}
    ],
    schema: [
      tasks: [type: {:list, :any}, default: []]
    ]
end
```

Plugins implement `Jido.Plugin` behaviour with callbacks: `plugin_spec/1`,
`handle_signal/2`, `transform_result/3`, and `child_spec/1`.

---

## Step 7: Lifecycle Hooks

Agents support two optional pure callbacks:

```elixir
def on_before_cmd(agent, action) do
  # Pre-processing: mirror params, enforce guards
  {:ok, agent, action}
end

def on_after_cmd(agent, action, directives) do
  # Post-processing: validate state, derive computed fields
  {:ok, agent, directives}
end
```

---

## Step 8: Run with AgentServer

For production, wrap agents in `AgentServer` — the OTP GenServer runtime:

```elixir
# Start under DynamicSupervisor
{:ok, pid} = Jido.AgentServer.start(agent: MyApp.TaskManager)

# Start linked
{:ok, pid} = Jido.AgentServer.start_link(
  agent: MyApp.TaskManager,
  id: "task-mgr-1",
  initial_state: %{status: :active}
)

# Send signals
:ok = Jido.AgentServer.call(pid, signal, timeout)
:ok = Jido.AgentServer.cast(pid, signal)

# Get state
{:ok, state} = Jido.AgentServer.state(pid)
```

Signal flow: `Signal → AgentServer → route → Agent.cmd/2 → {agent, directives} → drain loop`

---

## Common Patterns

### State Machine (FSM Strategy)

Use a strategy to enforce state transitions:

```elixir
use Jido.Agent,
  name: "order_agent",
  strategy: {MyApp.OrderFSM, %{initial: :pending}},
  schema: [
    status: [type: :atom, default: :pending],
    items: [type: {:list, :any}, default: []]
  ]
```

### Parent-Child Hierarchies

Jido supports logical parent-child relationships (not OTP supervision):

```elixir
{:ok, parent_pid} = Jido.AgentServer.start(agent: ParentAgent)
{:ok, child_pid} = Jido.AgentServer.start(
  agent: ChildAgent,
  parent: parent_pid,
  on_parent_death: :emit_orphan
)
```

---

## Complete Example: Task Manager Agent

```elixir
defmodule MyApp.Actions.AddTask do
  use Jido.Action,
    name: "add_task",
    description: "Adds a task to the list",
    schema: [
      title: [type: :string, required: true],
      priority: [type: :atom, default: :normal]
    ]

  @impl true
  def run(params, _context) do
    task = %{
      id: System.unique_integer([:positive]),
      title: params.title,
      priority: params.priority,
      completed: false
    }
    {:ok, %{
      tasks: :append,
      _append_tasks: task,
      task_count: :increment
    }}
  end
end

defmodule MyApp.Actions.CompleteTask do
  use Jido.Action,
    name: "complete_task",
    description: "Marks a task as completed",
    schema: [
      task_id: [type: :integer, required: true]
    ]

  @impl true
  def run(params, context) do
    tasks = context.state.tasks
    updated = Enum.map(tasks, fn
      %{id: id} = t when id == params.task_id -> %{t | completed: true}
      t -> t
    end)
    {:ok, %{tasks: updated}}
  end
end

defmodule MyApp.TaskManager do
  use Jido.Agent,
    name: "task_manager",
    description: "Manages tasks with priorities",
    schema: [
      tasks: [type: {:list, :any}, default: []],
      status: [type: :atom, default: :idle],
      task_count: [type: :integer, default: 0]
    ]

  def signal_routes(_ctx) do
    [
      {"task.add", MyApp.Actions.AddTask},
      {"task.complete", MyApp.Actions.CompleteTask}
    ]
  end
end
```

---

## DO / DON'T

### DO

- **Keep agents focused on one domain.** One agent = one bounded context.
- **Use schema validation for all state.** Define every field with types and defaults.
- **Test agents as pure functions first.** Call `cmd/2` on structs before testing with AgentServer.
- **Return directives for side effects.** Let the runtime handle I/O.
- **Use `signal_routes/1`** to map signals to actions declaratively.

### DON'T

- **Put side effects in actions used inside cmd/2.** Use directives to describe effects; let AgentServer execute them.
- **Access external state in cmd/2.** The agent should only use its own state and action params.
- **Skip schema validation.** Unvalidated state leads to subtle runtime bugs.
- **Use `{:stop, ...}` from DirectiveExec** for normal completion — use state-based completion instead.
- **Mutate agent state outside cmd/2 or set/2.** Always go through the defined API.
