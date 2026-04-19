# Jido Agents Reference

## Defining an Agent

Use the `Jido.Agent` macro to define an agent module:

```elixir
defmodule MyApp.Agents.OrderProcessor do
  use Jido.Agent,
    name: "order_processor",
    description: "Processes incoming orders",
    schema: [
      orders: [type: {:list, :map}, default: []],
      total_processed: [type: :integer, default: 0],
      status: [type: {:in, [:idle, :processing, :paused]}, default: :idle]
    ],
    actions: [
      MyApp.Actions.ProcessOrder,
      MyApp.Actions.CancelOrder
    ]
end
```

### Macro Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `name` | `string` | yes | Unique identifier for the agent type |
| `description` | `string` | yes | Human-readable description |
| `schema` | `keyword` | yes | NimbleOptions schema defining agent state |
| `actions` | `list` | no | Allowed action modules |
| `signal_routes` | `block` | no | Signal-to-action routing table |

## Schema Definition

Schemas use NimbleOptions syntax:

```elixir
schema: [
  field_name: [
    type: :string,          # :string, :integer, :float, :boolean, :atom, :map, {:list, type}
    required: true,          # default: false
    default: "value",        # default value
    doc: "Field description"
  ]
]
```

The schema defines the shape of `agent.state`. On `new/1`, fields are validated and defaults applied.

## Creating Agent Instances

```elixir
# With defaults
{:ok, agent} = OrderProcessor.new()

# With initial state
{:ok, agent} = OrderProcessor.new(%{status: :processing})
```

Returns a `Jido.Agent.t()` struct. The agent is a plain immutable data structure.

## The cmd/2 Contract

`cmd/2` is the **only** way to update agent state through actions:

```elixir
{updated_agent, directives} = MyAgent.cmd(agent, instruction)
```

### Instruction Formats

```elixir
# Single action, no params
MyAgent.cmd(agent, MyAction)

# Single action with params
MyAgent.cmd(agent, {MyAction, %{key: "value"}})

# Multiple actions (executed sequentially, state threaded through)
MyAgent.cmd(agent, [
  {FirstAction, %{x: 1}},
  {SecondAction, %{y: 2}}
])
```

### Return Value

`cmd/2` always returns `{agent, directives}`:

- `agent` — the updated agent struct with new state
- `directives` — a list of `Jido.Directive` structs describing side effects

If an action fails, `cmd/2` raises. Use `cmd/2` in a try/rescue or pattern match on action results in the action's `run/2`.

## Signal Routes

Define how the agent responds to signals at runtime:

```elixir
signal_routes do
  on "order.created", do: act(MyApp.Actions.ProcessOrder)
  on "order.cancelled", do: act(MyApp.Actions.CancelOrder)
  on "order.*", do: act(MyApp.Actions.LogOrder)
end
```

Signal routes are used by `AgentServer` to dispatch incoming signals to actions. Patterns support `*` wildcards.

## Plugins

Plugins are composable modules that extend an agent with additional state fields, actions, and signal routes:

```elixir
defmodule MyApp.Plugins.Auditable do
  use Jido.Plugin,
    name: "auditable",
    description: "Adds audit trail to any agent",
    schema: [
      audit_log: [type: {:list, :map}, default: []]
    ],
    actions: [MyApp.Actions.RecordAudit]

  signal_routes do
    on "audit.*", do: act(MyApp.Actions.RecordAudit)
  end
end

defmodule MyApp.Agents.AuditedOrder do
  use Jido.Agent,
    name: "audited_order",
    description: "Order processor with audit trail",
    schema: [...],
    plugins: [MyApp.Plugins.Auditable]
end
```

Plugin schemas, actions, and routes are merged into the agent at compile time.

## AgentServer (Runtime)

`AgentServer` wraps an agent in a GenServer for production use:

```elixir
# Start an agent process
{:ok, pid} = AgentServer.start_link(
  agent: MyApp.Agents.OrderProcessor,
  id: "order-123",
  initial_state: %{status: :idle}
)

# Send a synchronous command
{:ok, result} = AgentServer.call(pid, {ProcessOrder, %{order_id: "abc"}})

# Send an asynchronous command
:ok = AgentServer.cast(pid, {ProcessOrder, %{order_id: "def"}})

# Deliver a signal
AgentServer.signal(pid, signal)
```

`AgentServer` handles:
- Signal routing via `signal_routes`
- Directive execution (Emit, Spawn, etc.)
- Process lifecycle and supervision
- Parent-child agent hierarchies

## Parent-Child Hierarchies

Agents can spawn child agents using the `SpawnAgent` directive:

```elixir
def run(params, context) do
  {:ok, %{}, [
    %Jido.Directive.SpawnAgent{
      module: MyApp.Agents.Worker,
      id: "worker-#{params.task_id}",
      initial_state: %{task: params.task}
    }
  ]}
end
```

The parent `AgentServer` tracks children and can stop them with `StopChild`.

## Complete Example

```elixir
defmodule MyApp.Agents.Counter do
  use Jido.Agent,
    name: "counter",
    description: "Counts things",
    schema: [
      count: [type: :integer, default: 0],
      last_action: [type: :string, default: "none"]
    ],
    actions: [
      MyApp.Actions.Increment,
      MyApp.Actions.Reset
    ]

  signal_routes do
    on "counter.increment", do: act(MyApp.Actions.Increment)
    on "counter.reset", do: act(MyApp.Actions.Reset)
  end
end

# Interactive use
{:ok, agent} = Counter.new()
{agent, _directives} = Counter.cmd(agent, {Increment, %{amount: 10}})
agent.state.count #=> 10

# Production use
{:ok, pid} = AgentServer.start_link(agent: Counter, id: "counter-1")
AgentServer.signal(pid, %Jido.Signal{type: "counter.increment", data: %{amount: 5}})
```
