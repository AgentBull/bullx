# Jido Directives Reference

## What Are Directives?

Directives are **typed effect descriptions** — data structures that declare a side effect without executing it. Actions return directives alongside state updates; the runtime (`AgentServer`) processes them after `cmd/2` completes.

This separation keeps actions pure and testable while enabling real-world effects.

```elixir
# Inside an action's run/2
{:ok, %{status: :notified}, [
  %Jido.Directive.Emit{signal: my_signal},
  %Jido.Directive.Schedule{message: :check_status, delay: 5_000}
]}
```

## Directive Types

### Emit

Dispatch a signal to the signal bus.

```elixir
%Jido.Directive.Emit{
  signal: %Jido.Signal{
    type: "order.completed",
    source: "agent:order-123",
    data: %{order_id: "abc", total: 99.99}
  }
}
```

Use `Emit` to notify other agents or systems of events. The signal follows the CloudEvents spec.

### Spawn

Spawn a generic BEAM child process under the agent's supervisor.

```elixir
%Jido.Directive.Spawn{
  module: MyApp.Workers.FileProcessor,
  args: [path: "/tmp/upload.csv"],
  id: "file-worker-1"
}
```

The child is tracked by the agent's runtime. Use `StopChild` to terminate it.

### SpawnAgent

Spawn a child Jido agent as a managed process.

```elixir
%Jido.Directive.SpawnAgent{
  module: MyApp.Agents.TaskWorker,
  id: "task-worker-42",
  initial_state: %{task_id: "t-42", assigned_to: "agent-1"}
}
```

The child agent runs its own `AgentServer` and is supervised by the parent. Parent-child relationships enable hierarchical agent architectures.

### StopChild

Stop a tracked child process (spawned via `Spawn` or `SpawnAgent`).

```elixir
%Jido.Directive.StopChild{
  id: "task-worker-42"
}
```

### Schedule

Send a delayed message to the agent process.

```elixir
%Jido.Directive.Schedule{
  message: :timeout_check,
  delay: 10_000    # milliseconds
}
```

The message arrives as a signal that the agent can route via `signal_routes`. Use for timeouts, polling, or deferred work.

### Stop

Stop the agent process gracefully.

```elixir
%Jido.Directive.Stop{
  reason: :normal
}
```

The agent's `AgentServer` will shut down with the given reason. Use `:normal` for clean shutdowns.

## How the Runtime Processes Directives

After `cmd/2` returns `{agent, directives}`, the `AgentServer` processes each directive in order:

1. **Emit** — publishes the signal via `Jido.Signal.Bus`
2. **Spawn** — starts the child under the agent's `DynamicSupervisor`
3. **SpawnAgent** — starts a child `AgentServer` under supervision
4. **StopChild** — terminates the child and removes tracking
5. **Schedule** — calls `Process.send_after/3` on the agent process
6. **Stop** — initiates GenServer shutdown

Directives are processed sequentially in list order. If a directive fails, the error is logged and processing continues with the next directive.

## Returning Directives from Actions

Return directives as the third element of the success tuple:

```elixir
@impl true
def run(params, context) do
  # State update + multiple directives
  {:ok, %{status: :spawned}, [
    %Jido.Directive.SpawnAgent{
      module: WorkerAgent,
      id: "worker-#{params.task_id}",
      initial_state: %{task: params.task}
    },
    %Jido.Directive.Emit{
      signal: %Jido.Signal{type: "worker.spawned", data: %{task_id: params.task_id}}
    }
  ]}
end
```

## Testing Directives

Because directives are plain data, test them by inspecting the return value of `cmd/2`:

```elixir
test "spawns a worker on task assignment" do
  {:ok, agent} = TaskManager.new()
  {_agent, directives} = TaskManager.cmd(agent, {AssignTask, %{task_id: "t-1"}})

  assert [%Jido.Directive.SpawnAgent{id: "worker-t-1"}] = directives
end
```

No mocks needed — just assert on the directive structs.

## Custom Directives

Implement the `Jido.Directive` protocol to define custom directive types:

```elixir
defmodule MyApp.Directives.SendEmail do
  defstruct [:to, :subject, :body]
end

defimpl Jido.Directive, for: MyApp.Directives.SendEmail do
  def execute(directive, agent_state) do
    MyApp.Mailer.send(directive.to, directive.subject, directive.body)
    {:ok, agent_state}
  end
end
```

The runtime calls `Jido.Directive.execute/2` for each directive. Custom directives integrate seamlessly with the standard processing pipeline.
