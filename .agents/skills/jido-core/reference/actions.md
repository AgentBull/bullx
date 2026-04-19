# Jido Actions Reference

## Defining an Action

Use the `Jido.Action` macro to define a composable, validated action:

```elixir
defmodule MyApp.Actions.CreateOrder do
  use Jido.Action,
    name: "create_order",
    description: "Creates a new order from the given items",
    schema: [
      items: [type: {:list, :map}, required: true, doc: "List of order items"],
      customer_id: [type: :string, required: true],
      priority: [type: {:in, [:low, :normal, :high]}, default: :normal]
    ]

  @impl true
  def run(params, context) do
    order = %{
      id: Jido.Util.generate_id(),
      items: params.items,
      customer_id: params.customer_id,
      priority: params.priority,
      created_at: DateTime.utc_now()
    }

    {:ok, %{orders: [order | context.state.orders], total_processed: context.state.total_processed + 1}}
  end
end
```

### Macro Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `name` | `string` | yes | Unique identifier for the action |
| `description` | `string` | yes | Human-readable description |
| `schema` | `keyword` | yes | NimbleOptions schema for params validation |

## The run/2 Callback

Every action must implement `run/2`:

```elixir
@impl true
def run(params, context) do
  # params — validated against schema, defaults applied
  # context — contains agent state, metadata, and runtime info
  {:ok, %{field: new_value}}
end
```

### Parameters

`params` is a map with keys matching the schema. Validation happens before `run/2` is called — if params are invalid, `run/2` is never invoked.

### Context

`context` provides access to agent state and runtime information:

```elixir
context.state        # Current agent state (map)
context.agent        # The full agent struct
```

### Return Values

| Return | Meaning |
|--------|---------|
| `{:ok, map}` | State update — map is merged into agent state |
| `{:ok, map, directives}` | State update + directives for side effects |
| `{:error, reason}` | Failure — action chain halts, error propagates |

```elixir
# State update only
{:ok, %{count: context.state.count + 1}}

# State update with directives
{:ok, %{status: :notified}, [
  %Jido.Directive.Emit{signal: %Jido.Signal{type: "order.created", data: %{id: order_id}}}
]}

# Failure
{:error, "Insufficient inventory for item #{params.item_id}"}
```

## Schema Validation

Schemas use NimbleOptions. Common types:

```elixir
schema: [
  name: [type: :string, required: true],
  count: [type: :integer, default: 0],
  ratio: [type: :float],
  active: [type: :boolean, default: true],
  mode: [type: {:in, [:fast, :slow]}],
  tags: [type: {:list, :string}, default: []],
  metadata: [type: :map, default: %{}],
  callback: [type: {:fun, 1}]
]
```

Invalid params raise before `run/2` executes. You do not need to validate schema-declared fields inside `run/2`.

## Action Composition

Actions compose by chaining in `cmd/2`. State threads through sequentially:

```elixir
{agent, directives} = MyAgent.cmd(agent, [
  {ValidateOrder, %{order_id: "abc"}},
  {CalculateTotal, %{}},
  {ApplyDiscount, %{code: "SAVE10"}},
  {FinalizeOrder, %{}}
])
```

Each action receives the state produced by the previous action. If any action returns `{:error, reason}`, the chain halts immediately.

### Composition Guidelines

- Keep actions small and focused — one responsibility per action.
- Use action chains for multi-step workflows.
- Earlier actions can set state fields that later actions read.
- Order matters — arrange actions so dependencies flow forward.

## Actions Are Pure

Actions must be pure data transformations:

**Do:**
- Read from `params` and `context.state`
- Return state update maps
- Return directives for side effects

**Do not:**
- Make HTTP calls directly
- Write to disk or databases
- Send messages to other processes
- Access global state or application env

Side effects belong in directives. The runtime (`AgentServer`) executes directives after `cmd/2` completes.

## Complete Example

```elixir
defmodule MyApp.Actions.TransferFunds do
  use Jido.Action,
    name: "transfer_funds",
    description: "Transfer funds between accounts",
    schema: [
      from: [type: :string, required: true, doc: "Source account ID"],
      to: [type: :string, required: true, doc: "Destination account ID"],
      amount: [type: :float, required: true, doc: "Transfer amount"]
    ]

  @impl true
  def run(params, context) do
    balance = Map.get(context.state.balances, params.from, 0.0)

    if balance < params.amount do
      {:error, "Insufficient funds in account #{params.from}"}
    else
      updated_balances =
        context.state.balances
        |> Map.update(params.from, 0.0, &(&1 - params.amount))
        |> Map.update(params.to, 0.0, &(&1 + params.amount))

      {:ok, %{balances: updated_balances, last_transfer: DateTime.utc_now()}, [
        %Jido.Directive.Emit{
          signal: %Jido.Signal{
            type: "funds.transferred",
            data: %{from: params.from, to: params.to, amount: params.amount}
          }
        }
      ]}
    end
  end
end
```
