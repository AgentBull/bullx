---
name: jido-action
description: >-
  Create composable, validated Jido Actions using the Action behaviour.
  Use when defining new actions, working with action schemas, composing
  action chains, or debugging action execution.
metadata:
  author: agentjido
  version: "0.1.0"
license: Apache-2.0
---

# Building Jido Actions

## MANDATORY PREPARATION

Invoke $jido-core first — it contains ecosystem context,
conventions, and core design principles. Follow its guidance before proceeding.

## Overview

A Jido Action is a discrete, composable unit of functionality. Actions are
defined at **compile-time** with validated schemas and executed via `run/2`.

Actions can be:
- Called directly with `Jido.Exec.run/3`
- Composed into chains with `Jido.Exec.Chain`
- Used inside agents via `cmd/2`
- Exposed as LLM-callable tools via `to_tool/0`

---

## Step 1: Define an Action

```elixir
defmodule MyApp.Actions.ProcessData do
  use Jido.Action,
    name: "process_data",
    description: "Transforms and validates input data",
    category: "processing",
    tags: ["data", "transform"],
    vsn: "1.0.0",
    schema: [
      input: [type: :string, required: true, doc: "Raw input data"],
      format: [type: :atom, default: :json, doc: "Output format"]
    ],
    output_schema: [
      result: [type: :string, required: true],
      byte_count: [type: :integer, required: true]
    ]

  @impl true
  def run(params, _context) do
    result = transform(params.input, params.format)
    {:ok, %{result: result, byte_count: byte_size(result)}}
  end

  defp transform(input, :json), do: Jason.encode!(input)
  defp transform(input, :text), do: to_string(input)
end
```

### Configuration Options

| Option          | Type        | Required | Description                       |
|-----------------|-------------|----------|-----------------------------------|
| `name`          | string      | yes      | Snake_case identifier             |
| `description`   | string      | no       | What the action does              |
| `category`      | string      | no       | Grouping category                 |
| `tags`          | list        | no       | Discovery tags                    |
| `vsn`           | string      | no       | Version                           |
| `schema`        | keyword     | no       | NimbleOptions or Zoi input schema |
| `output_schema` | keyword     | no       | NimbleOptions or Zoi output schema|

---

## Step 2: Implement run/2

The `run/2` callback receives validated params and a context map:

```elixir
@impl true
def run(params, context) do
  # params — validated against schema, keys are atoms
  # context — map with execution context (e.g., agent state)
  {:ok, %{result: "processed"}}
end
```

### Return Values

| Return                        | Meaning                              |
|-------------------------------|--------------------------------------|
| `{:ok, %{key: value}}`       | Success with state updates           |
| `{:ok, %{result: v}, extras}`| Success with extras (e.g., directives)|
| `{:error, reason}`           | Failure                              |

**Validation is open**: only fields in the schema are validated. Unspecified
fields pass through, enabling action composition without validation conflicts.

---

## Step 3: Schema Validation

Schemas validate input params at runtime. Use NimbleOptions types:

```elixir
schema: [
  name: [type: :string, required: true, doc: "User name"],
  age: [type: :integer, default: 0],
  role: [type: {:in, [:admin, :user, :guest]}, default: :user],
  tags: [type: {:list, :string}, default: []],
  metadata: [type: :map, default: %{}]
]
```

Or use Zoi schemas (recommended for new code):

```elixir
schema: Zoi.object(%{
  name: Zoi.string() |> Zoi.min_length(1),
  age: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
  role: Zoi.enum([:admin, :user, :guest]) |> Zoi.default(:user)
})
```

Validate params programmatically:

```elixir
{:ok, validated} = MyApp.Actions.ProcessData.validate_params(%{input: "hello"})
{:ok, validated} = MyApp.Actions.ProcessData.validate_output(%{result: "ok", byte_count: 2})
```

---

## Step 4: Lifecycle Hooks

Actions support optional callbacks for pre/post processing:

```elixir
defmodule MyApp.Actions.Enriched do
  use Jido.Action,
    name: "enriched_action",
    schema: [value: [type: :integer, required: true]]

  @impl true
  def on_before_validate_params(params) do
    # Normalize before validation
    {:ok, Map.update(params, :value, 0, &abs/1)}
  end

  @impl true
  def on_after_validate_params(params) do
    # Post-validation transforms
    {:ok, params}
  end

  @impl true
  def run(params, _context) do
    {:ok, %{doubled: params.value * 2}}
  end

  @impl true
  def on_after_run(result) do
    # Post-processing on the result
    result
  end

  @impl true
  def on_error(failed_params, error, _context, _opts) do
    # Compensation logic on failure
    {:ok, %{compensated: true, original_error: error}}
  end
end
```

| Callback                     | When                          | Default        |
|------------------------------|-------------------------------|----------------|
| `on_before_validate_params/1`| Before param validation       | passthrough    |
| `on_after_validate_params/1` | After param validation        | passthrough    |
| `on_after_run/1`             | After run/2 completes         | passthrough    |
| `on_error/4`                 | On execution failure          | passthrough    |

---

## Step 5: Execute Actions

### Direct Execution with Jido.Exec

```elixir
# Basic execution
{:ok, result} = Jido.Exec.run(MyApp.Actions.ProcessData, %{input: "hello"})

# With context
{:ok, result} = Jido.Exec.run(MyApp.Actions.ProcessData, %{input: "hello"}, %{user_id: 1})

# Async execution
async_ref = Jido.Exec.run_async(MyApp.Actions.ProcessData, %{input: "hello"})
{:ok, result} = Jido.Exec.await(async_ref)
```

### Action Chains

Execute multiple actions in sequence — output flows into the next action's input:

```elixir
alias Jido.Exec.Chain

{:ok, result} = Chain.run(
  [
    {ValidateInput, %{raw: data}},
    {TransformData, %{}},
    {SaveResult, %{destination: :database}}
  ],
  %{},    # initial context
  []      # options
)
```

### Action Closures

Pre-apply params and context for deferred execution:

```elixir
alias Jido.Exec.Closure

closure = Closure.new(MyAction, %{preset: "value"}, %{env: :prod})
{:ok, result} = Closure.run(closure, %{additional: "param"})
```

---

## Step 6: Inside Agents

Actions are the building blocks of agent commands:

```elixir
# In agent signal_routes
def signal_routes(_ctx) do
  [
    {"data.process", MyApp.Actions.ProcessData},
    {"data.validate", {MyApp.Actions.Validate, %{strict: true}}}
  ]
end

# Direct cmd/2 usage
{agent, directives} = MyAgent.cmd(agent, {MyApp.Actions.ProcessData, %{input: "data"}})
```

---

## Step 7: AI Tool Integration

Actions can be exposed as LLM-callable tools:

```elixir
# Convert to tool format
tool_spec = MyApp.Actions.ProcessData.to_tool()
# => %{
#   "name" => "process_data",
#   "description" => "Transforms and validates input data",
#   "parameters" => %{
#     "type" => "object",
#     "properties" => %{
#       "input" => %{"type" => "string", "description" => "Raw input data"},
#       "format" => %{"type" => "string", "description" => "Output format"}
#     },
#     "required" => ["input"]
#   }
# }
```

The `schema` and `doc` strings directly map to tool parameter descriptions.
Use descriptive `doc` values in your schema for best AI tool integration.

---

## Complete Example: Data Pipeline Action

```elixir
defmodule MyApp.Actions.EnrichUser do
  use Jido.Action,
    name: "enrich_user",
    description: "Enriches a user record with computed fields",
    schema: [
      user_id: [type: :integer, required: true, doc: "User ID to enrich"],
      include_stats: [type: :boolean, default: false, doc: "Include usage statistics"]
    ],
    output_schema: [
      user: [type: :map, required: true],
      enriched_at: [type: :string, required: true]
    ]

  @impl true
  def run(params, context) do
    user = context.state.users[params.user_id]

    enriched = user
    |> Map.put(:full_name, "#{user.first_name} #{user.last_name}")
    |> maybe_add_stats(params.include_stats, context)

    {:ok, %{user: enriched, enriched_at: DateTime.utc_now() |> to_string()}}
  end

  defp maybe_add_stats(user, false, _ctx), do: user
  defp maybe_add_stats(user, true, ctx) do
    Map.put(user, :login_count, length(ctx.state.login_history[user.id] || []))
  end
end
```

---

## DO / DON'T

### DO

- **Name actions with snake_case.** Must contain only letters, numbers, underscores.
- **Add `doc` to schema fields.** These become tool descriptions for LLM integration.
- **Return `{:ok, map}` from run/2.** Always return a map of state updates.
- **Use output_schema** to validate action outputs for downstream consumers.
- **Keep actions focused.** One action = one logical operation.

### DON'T

- **Define actions at runtime.** `Jido.Action.new()` raises — actions are compile-time only.
- **Depend on action execution order** unless using explicit chains.
- **Mutate external state in run/2 inside cmd/2** without understanding the purity boundary — use directives for effects owned by the runtime.
- **Ignore error returns.** Always pattern match on `{:ok, _}` or `{:error, _}`.
- **Use overly broad schemas.** Validate what you need; let composition handle the rest.
