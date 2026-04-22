# RFC 0000: Architecture Scaffolding

- **Author**: Boris Ding
- **Created**: 2026-04-19
- **Supersedes**: `rfcs/drafts/Architecture.md`

## 1. Purpose

Establish the skeletal structure of the BullX codebase so that subsequent RFCs can fill in each subsystem independently.

This RFC introduces only namespace modules and empty supervisors. Nothing runs, nothing decides, nothing persists. A successful execution of this RFC produces a codebase that compiles, passes tests, starts `mix phx.server`, and shows the default Phoenix landing page — with every subsystem supervisor present in the process tree but holding zero children.

## 2. Context

BullX is organized into six subsystems. See [`AGENTS.md`](../../AGENTS.md) for the authoritative description of what each subsystem owns and the Jido ecosystem primer; this RFC does not duplicate that material.

Five subsystems are new and need to be scaffolded here. The sixth, `BullXWeb`, is the default Phoenix app that shipped with `mix phx.new` and is left untouched by this RFC.

BullX is a single `:bullx` OTP application. Subsystems are placed on one of two tiers inside that application — L1 (nested under core) or L2 (top-level namespace peer of core, same pattern as Phoenix's `bullx_web`). See [`AGENTS.md`](../../AGENTS.md) §Subsystems for the full tier definitions.

| Subsystem | New in RFC-0? | Tier | Path | Top-level module | Shape |
| --- | --- | --- | --- | --- | --- |
| Gateway | yes | L2 | `lib/bullx_gateway/` | `BullXGateway` | Namespace + empty top-level supervisor (`BullXGateway.CoreSupervisor`) |
| Brain | yes | L2 | `lib/bullx_brain/` | `BullXBrain` | Namespace + empty top-level supervisor |
| AIAgent | yes | L2 | `lib/bullx_ai_agent.ex` | `BullXAIAgent` | Namespace only (pure library, no supervisor) |
| Runtime | yes | L1 | `lib/bullx/runtime/` | `BullX.Runtime` | Namespace + empty top-level supervisor |
| Skills | yes | L1 | `lib/bullx/skills/` | `BullX.Skills` | Namespace + empty top-level supervisor |
| Web / control plane | no | L2 | `lib/bullx_web/` | `BullXWeb` | Preserved as-is |

## 3. Scope

### 3.1 In scope

- Create one namespace module per new subsystem at its target tier: Gateway at `lib/bullx_gateway.ex` + `lib/bullx_gateway/`, Brain at `lib/bullx_brain.ex` + `lib/bullx_brain/`, AIAgent at `lib/bullx_ai_agent.ex`, Runtime and Skills nested under `lib/bullx/`.
- Create one empty `Supervisor` module for each of Gateway, Runtime, Brain, Skills.
- Register each subsystem supervisor as a child of `BullX.Application` in a deterministic RFC-0 boot order.
- Treat that boot order as scaffolding only. Later subsystem RFCs may reorder or split those supervisors once they stop being empty shells.
- Add smoke tests that verify each supervisor is alive after boot and holds zero children.

### 3.2 Out of scope

- **External dependencies.** No new package is added to `mix.exs`. The default dependency set from `mix phx.new` is sufficient for this RFC, and subsequent RFCs will add the libraries they need (Jido, Ash, etc.) as part of their own scope.
- **Inner supervision.** Registries, `DynamicSupervisor`s, `Task.Supervisor`s, `GenServer`s — anything that would live *under* a subsystem supervisor — are deferred to the subsystem-specific RFC that implements behavior.
- **Behavior.** No schema, migration, Ash resource, Ecto context, adapter implementation, LLM integration, prompt type, reasoning strategy, workflow engine, scheduler, consolidation job, skill, or frontend change belongs in this RFC.
- **BullXWeb.** The existing Phoenix scaffold is left alone. The eventual migration to Ash JSON API + Vite SPA is a separate RFC.
- **packages/** is not touched. `packages/` is reserved for externally reusable libraries (e.g. `packages/feishu_openapi/`); BullX-internal subsystems live in `lib/` as L1 or L2 namespaces, never as separate mix projects.

## 4. Target structure

After this RFC, `lib/` contains exactly these files (plus `lib/bullx_web/` which this RFC does not touch):

```
lib/
├── bullx.ex                    (unchanged)
├── bullx/
│   ├── application.ex          (MODIFIED — extended children list)
│   ├── mailer.ex               (unchanged)
│   ├── repo.ex                 (unchanged)
│   ├── runtime.ex              (NEW — namespace module, BullX.Runtime)
│   ├── runtime/
│   │   └── supervisor.ex       (NEW — empty supervisor)
│   ├── skills.ex               (NEW — namespace module, BullX.Skills)
│   └── skills/
│       └── supervisor.ex       (NEW — empty supervisor)
├── bullx_gateway.ex            (NEW — namespace module, BullXGateway)
├── bullx_gateway/
│   └── core_supervisor.ex      (NEW — empty supervisor, BullXGateway.CoreSupervisor)
├── bullx_brain.ex              (NEW — namespace module, BullXBrain)
├── bullx_brain/
│   └── supervisor.ex           (NEW — empty supervisor, BullXBrain.Supervisor)
└── bullx_ai_agent.ex           (NEW — namespace module, BullXAIAgent; no supervisor)
```

No other file under `lib/`, `config/`, `priv/`, `assets/`, `packages/`, or `test/support/` is created or modified by this RFC, except for the test file listed in §7.

## 5. Module specifications

### 5.1 Namespace modules

Each of `BullXGateway`, `BullX.Runtime`, `BullXAIAgent`, `BullXBrain`, `BullX.Skills` is a single-file module whose only content is a `@moduledoc`. The moduledoc text should be a one- to three-sentence summary taken directly from the corresponding row in `AGENTS.md` §Subsystems, followed by a single line indicating the RFC-0 status. Example:

```elixir
defmodule BullXGateway do
  @moduledoc """
  Multi-transport ingress and egress. Normalizes inbound events from external
  sources (HTTP polling, subscribed WebSockets, webhooks, ...) into internal
  signals, and dispatches outbound messages back to those destinations.

  RFC-000 establishes the namespace and an empty top-level supervisor; transport
  adapters are added by later RFCs.
  """
end
```

`BullXAIAgent` has no supervisor and its moduledoc should say so — it is a pure library namespace for Agent behaviors, prompt types, and reasoning strategies that later RFCs will populate. The forthcoming jido_ai fork will land inside `lib/bullx_ai_agent/` under the same namespace.

### 5.2 Supervisor modules

`BullXGateway.CoreSupervisor`, `BullX.Runtime.Supervisor`, `BullXBrain.Supervisor`, `BullX.Skills.Supervisor` are each a minimal `Supervisor` that boots with no children:

```elixir
defmodule BullXGateway.CoreSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
```

All four files are structurally identical except for the module name and file location.

### 5.3 Application tree

`BullX.Application.start/2` is extended to include the subsystem supervisors in its children list, placed between the existing Phoenix infrastructure and `BullXWeb.Endpoint`. The list below is the RFC-0 scaffolding shape only; later subsystem RFCs may refine it once the supervisors gain real behavior:

```elixir
children = [
  BullXWeb.Telemetry,
  BullX.Repo,
  BullX.Config.Supervisor,
  {DNSCluster, query: Application.get_env(:bullx, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: BullX.PubSub},

  # BullX subsystems
  BullXGateway.CoreSupervisor,
  BullX.Skills.Supervisor,
  BullXBrain.Supervisor,
  BullX.Runtime.Supervisor,
  BullXGateway.AdapterSupervisor,

  BullXWeb.Endpoint
]
```

This ordering exists only to keep the initial scaffold deterministic while the supervisors are empty. It is not a long-term architectural contract.

Later RFCs are allowed to tighten the startup constraints as behavior is introduced. In particular, the Gateway implementation RFC supersedes the RFC-0 "Runtime before Gateway" assumption with a stricter partial order:

- `BullX.Repo` must be available before `BullXGateway.CoreSupervisor`.
- `BullXGateway.CoreSupervisor` must start before `BullX.Runtime.Supervisor`.
- `BullXGateway.AdapterSupervisor` must be attached explicitly by the application only after Runtime is ready, replacing a global ingress on/off switch.

Stated as the relevant sequence constraint, the later order is `Repo -> BullXGateway.CoreSupervisor -> BullX.Runtime.Supervisor -> BullXGateway.AdapterSupervisor`.

## 6. Non-goals and invariants

The executing agent must not:

- Add any dependency to `mix.exs` or any package manifest.
- Add any configuration entry to `config/*.exs`.
- Add any migration under `priv/repo/migrations/`.
- Create any file not listed in §4.
- Place any child in the new supervisors' `init/1` lists.
- Modify `lib/bullx_web/`, `assets/`, or `packages/`.
- Reference `Jido`, `Ash`, or any Hex package that isn't already in the current `mix.exs`.

If a subsystem RFC later needs to add inner children, split a top-level supervisor, or tighten startup ordering, that RFC owns the change to `lib/bullx/<subsystem>/supervisor.ex` and the application child list.

## 7. Tests

Add exactly one new test file, `test/bullx/application_test.exs`:

```elixir
defmodule BullX.ApplicationTest do
  use ExUnit.Case, async: false

  @supervisors [
    BullX.Skills.Supervisor,
    BullXBrain.Supervisor,
    BullX.Runtime.Supervisor,
    BullXGateway.CoreSupervisor
  ]

  test "each subsystem supervisor is running under the application" do
    for sup <- @supervisors do
      assert is_pid(Process.whereis(sup)), "#{inspect(sup)} is not running"
    end
  end

  test "each subsystem supervisor boots with zero children" do
    for sup <- @supervisors do
      assert %{active: 0, specs: 0, workers: 0, supervisors: 0} =
               Supervisor.count_children(sup)
    end
  end
end
```

No other test files are added. The existing `test/bullx_web/` and `test/support/` trees remain untouched.

## 8. Acceptance criteria

A coding agent has completed this RFC when all of the following hold:

1. `mix deps.get` runs with no change to `mix.lock` (the RFC introduces no new dependency).
2. `mix compile --warnings-as-errors` succeeds.
3. `mix format --check-formatted` succeeds.
4. `mix test` passes, including the two new assertions in `test/bullx/application_test.exs`.
5. `mix precommit` passes end-to-end.
6. `mix phx.server` starts and the default Phoenix landing page is served at `GET /`.
7. `lib/bullx/` contains exactly the files listed in §4 — no more, no fewer.
8. In `:observer.start()`, the four new supervisors are visible under `BullX.Supervisor`, each with zero children.

These acceptance criteria describe RFC-0 completion only. Later RFCs may reorder the subsystem boot sequence or replace a scaffold supervisor with a more specific split supervisor as real behavior is introduced.

If any criterion fails, the RFC is not complete.
