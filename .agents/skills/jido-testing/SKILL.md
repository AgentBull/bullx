---
name: jido-testing
description: >-
  Test Jido agents and actions effectively without OTP processes.
  Use when writing tests for agents, actions, plugins, or signal handling.
  Covers unit testing, property-based testing, and integration testing patterns.
metadata:
  author: agentjido
  version: "0.1.0"
license: Apache-2.0
---

# Testing Jido Agents and Actions

## MANDATORY PREPARATION

Invoke $jido-core first — it contains ecosystem context,
conventions, and core design principles. Follow its guidance before proceeding.

## Core Principle

Jido agents are **pure data** — test them without GenServer. Call `cmd/2` on
agent structs, assert state changes and directives. Only use `AgentServer`
for integration tests that need signal routing and directive execution.

---

## Step 1: Testing Actions

Actions are the simplest unit to test. Call `run/2` directly:

```elixir
defmodule MyApp.Actions.IncrementTest do
  use ExUnit.Case, async: true

  alias MyApp.Actions.Increment

  test "increments counter by amount" do
    params = %{amount: 5}
    context = %{state: %{counter: 10}}

    assert {:ok, %{counter: 15}} = Increment.run(params, context)
  end

  test "defaults amount to 1" do
    params = %{}
    context = %{state: %{counter: 0}}

    assert {:ok, %{counter: 1}} = Increment.run(params, context)
  end

  test "rejects negative amounts" do
    assert {:error, _reason} = Increment.validate_params(%{amount: -1})
  end
end
```

### Validate Params and Output

```elixir
test "validates input schema" do
  assert {:ok, %{input: "hello"}} = MyAction.validate_params(%{input: "hello"})
  assert {:error, _} = MyAction.validate_params(%{input: 123})
end

test "validates output schema" do
  assert {:ok, %{result: "ok"}} = MyAction.validate_output(%{result: "ok", byte_count: 2})
end
```

### Execute Through Jido.Exec

For full execution with validation and lifecycle hooks:

```elixir
test "full execution pipeline" do
  assert {:ok, result} = Jido.Exec.run(MyAction, %{input: "test"}, %{})
  assert result.processed == true
end
```

---

## Step 2: Testing Agents

Test agents as pure functions using `cmd/2` on structs:

```elixir
defmodule MyApp.CounterAgentTest do
  use ExUnit.Case, async: true

  alias MyApp.CounterAgent
  alias MyApp.Actions.{Increment, Decrement}

  setup do
    agent = CounterAgent.new()
    %{agent: agent}
  end

  test "new agent has default state", %{agent: agent} do
    assert agent.state.counter == 0
    assert agent.state.status == :idle
  end

  test "cmd/2 with single action", %{agent: agent} do
    {agent, directives} = CounterAgent.cmd(agent, {Increment, %{amount: 5}})

    assert agent.state.counter == 5
    assert directives == []
  end

  test "cmd/2 with action list", %{agent: agent} do
    {agent, directives} = CounterAgent.cmd(agent, [
      {Increment, %{amount: 3}},
      {Increment, %{amount: 7}}
    ])

    assert agent.state.counter == 10
    assert directives == []
  end

  test "cmd/2 returns directives for effects", %{agent: agent} do
    {_agent, directives} = CounterAgent.cmd(agent, NotifyAction)

    assert [%Jido.Agent.Directive.Emit{} | _] = directives
  end

  test "set/2 updates state", %{agent: agent} do
    {:ok, agent} = CounterAgent.set(agent, %{counter: 42})
    assert agent.state.counter == 42
  end
end
```

### Testing with Custom Initial State

```elixir
test "agent with initial state" do
  agent = CounterAgent.new(state: %{counter: 100, status: :active})
  assert agent.state.counter == 100

  {agent, _} = CounterAgent.cmd(agent, {Decrement, %{amount: 25}})
  assert agent.state.counter == 75
end
```

---

## Step 3: Testing Lifecycle Hooks

```elixir
test "on_before_cmd is called before processing" do
  agent = HookAgent.new()
  {agent, _directives} = HookAgent.cmd(agent, SomeAction)

  # Verify hook side-effects in state
  assert agent.state.hook_called == true
end

test "on_after_cmd can transform directives" do
  agent = HookAgent.new()
  {_agent, directives} = HookAgent.cmd(agent, SomeAction)

  # Verify directives were transformed by hook
  assert length(directives) > 0
end
```

---

## Step 4: Testing Plugins

Verify plugin state isolation and signal handling:

```elixir
defmodule MyApp.AuditPluginTest do
  use ExUnit.Case, async: true

  test "plugin state is isolated under its state_key" do
    agent = AgentWithAuditPlugin.new()

    # Plugin state is nested under its key
    assert agent.state.__audit_log__ == %{entries: []}
  end

  test "plugin signal handling" do
    agent = AgentWithAuditPlugin.new()
    {agent, _} = AgentWithAuditPlugin.cmd(agent, SomeTrackedAction)

    # Verify plugin transformed state
    assert length(agent.state.__audit_log__.entries) > 0
  end
end
```

---

## Step 5: Property-Based Testing with StreamData

Use StreamData for generative testing of actions:

```elixir
defmodule MyApp.Actions.MathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MyApp.Actions.Add

  property "addition is commutative" do
    check all a <- integer(),
              b <- integer() do
      assert {:ok, %{result: r1}} = Add.run(%{a: a, b: b}, %{})
      assert {:ok, %{result: r2}} = Add.run(%{a: b, b: a}, %{})
      assert r1 == r2
    end
  end

  property "counter never goes negative with abs_increment" do
    check all amounts <- list_of(positive_integer(), min_length: 1) do
      agent = CounterAgent.new()

      agent =
        Enum.reduce(amounts, agent, fn amount, acc ->
          {acc, _} = CounterAgent.cmd(acc, {Increment, %{amount: amount}})
          acc
        end)

      assert agent.state.counter > 0
    end
  end
end
```

---

## Step 6: Integration Testing with AgentServer

For tests that need the full OTP runtime, use `JidoTest.Case`:

```elixir
defmodule MyApp.CounterIntegrationTest do
  use JidoTest.Case, async: true

  alias Jido.AgentServer
  alias MyApp.CounterAgent

  test "signal routing through AgentServer", %{jido: jido} do
    pid = start_server(%{jido: jido}, CounterAgent)

    # Create and send a signal
    sig = signal("increment", %{amount: 5})
    :ok = AgentServer.call(pid, sig, 5_000)

    # Check agent state
    {:ok, state} = AgentServer.state(pid)
    assert state.agent.state.counter == 5
  end

  test "async signal processing", %{jido: jido} do
    pid = start_server(%{jido: jido}, CounterAgent)

    sig = signal("increment", %{amount: 1})
    :ok = AgentServer.cast(pid, sig)

    # Use eventually for async assertions
    assert_eventually fn ->
      {:ok, state} = AgentServer.state(pid)
      state.agent.state.counter == 1
    end
  end
end
```

### JidoTest.Case Helpers

| Helper                | Description                                    |
|-----------------------|------------------------------------------------|
| `start_server/3`     | Starts AgentServer with auto-cleanup           |
| `signal/3`           | Creates a test signal with defaults            |
| `unique_id/1`        | Generates unique ID with prefix                |
| `test_registry/1`    | Returns registry for test's Jido instance      |
| `assert_eventually/1`| Polling assertion for async results            |

Each test gets an isolated Jido instance via the `%{jido: jido}` context.

---

## Step 7: Mocking External Dependencies

Use Mimic for mocking external services:

```elixir
# test/test_helper.exs
Mimic.copy(MyApp.ExternalAPI)

# In test
defmodule MyApp.WeatherActionTest do
  use ExUnit.Case, async: true
  use Mimic

  test "handles API errors gracefully" do
    stub(MyApp.ExternalAPI, :fetch_weather, fn _location ->
      {:error, :timeout}
    end)

    assert {:error, _} = MyApp.Actions.GetWeather.run(%{location: "Tokyo"}, %{})
  end

  test "returns weather data on success" do
    expect(MyApp.ExternalAPI, :fetch_weather, fn "Tokyo" ->
      {:ok, %{temp: 22, conditions: "sunny"}}
    end)

    assert {:ok, %{temperature: 22}} = MyApp.Actions.GetWeather.run(%{location: "Tokyo"}, %{})
  end
end
```

---

## Step 8: Running the Test Suite

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/my_agent_test.exs

# Run specific test by line
mix test test/my_agent_test.exs:42

# Full quality check (formatting, credo, dialyzer, tests)
mix quality
```

---

## Complete Example: Counter Agent Test Module

```elixir
defmodule MyApp.CounterTest do
  use ExUnit.Case, async: true

  defmodule IncrementAction do
    use Jido.Action,
      name: "increment",
      schema: [amount: [type: :integer, default: 1]]

    @impl true
    def run(params, context) do
      {:ok, %{counter: (context.state[:counter] || 0) + params.amount}}
    end
  end

  defmodule DecrementAction do
    use Jido.Action,
      name: "decrement",
      schema: [amount: [type: :integer, default: 1]]

    @impl true
    def run(params, context) do
      {:ok, %{counter: (context.state[:counter] || 0) - params.amount}}
    end
  end

  defmodule CounterAgent do
    use Jido.Agent,
      name: "test_counter",
      schema: [counter: [type: :integer, default: 0]]

    def signal_routes(_ctx) do
      [
        {"increment", IncrementAction},
        {"decrement", DecrementAction}
      ]
    end
  end

  setup do
    %{agent: CounterAgent.new()}
  end

  test "starts at zero", %{agent: agent} do
    assert agent.state.counter == 0
  end

  test "increments by default amount", %{agent: agent} do
    {agent, []} = CounterAgent.cmd(agent, IncrementAction)
    assert agent.state.counter == 1
  end

  test "increments by custom amount", %{agent: agent} do
    {agent, []} = CounterAgent.cmd(agent, {IncrementAction, %{amount: 10}})
    assert agent.state.counter == 10
  end

  test "decrements", %{agent: agent} do
    {agent, []} = CounterAgent.cmd(agent, {IncrementAction, %{amount: 5}})
    {agent, []} = CounterAgent.cmd(agent, {DecrementAction, %{amount: 3}})
    assert agent.state.counter == 2
  end

  test "chains multiple actions", %{agent: agent} do
    {agent, []} = CounterAgent.cmd(agent, [
      {IncrementAction, %{amount: 10}},
      {DecrementAction, %{amount: 3}},
      {IncrementAction, %{amount: 1}}
    ])
    assert agent.state.counter == 8
  end
end
```

---

## DO / DON'T

### DO

- **Test agents as pure data first.** Use `cmd/2` on structs before involving AgentServer.
- **Use `async: true`** on all tests that don't share mutable state.
- **Use `JidoTest.Case`** for integration tests — it provides isolated Jido instances.
- **Use `assert_eventually`** for async assertions instead of `Process.sleep`.
- **Test actions in isolation** with `run/2` before testing inside agents.

### DON'T

- **Start GenServers in unit tests.** Test pure logic first.
- **Use `Process.sleep`** for timing — use `assert_eventually` or proper await.
- **Share state between tests.** Each test should create its own agent struct.
- **Skip schema validation tests.** Verify your schemas reject bad input.
- **Mock internal Jido modules.** Mock external boundaries only.
