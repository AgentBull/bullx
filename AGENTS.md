# BullX Agent Guidelines

BullX is a highly available, self-evolving AI Agent Operating System built on Elixir/OTP and PostgreSQL. The codebase is organized into six subsystems that boot under a single OTP supervision tree. PostgreSQL is the system of record for sessions, memory, and knowledge; process-local state is ephemeral and reconstructible on restart.

## The Zen of BullX Development

Do the task that was asked.

Do not silently change the task.

Correct is better than clever.

Consistent is better than complete.

Useful is better than theoretically perfect.

A deliberate tradeoff is not a bug.

A local preference is not an architecture finding.

Omissions matter.

Contradictions matter.

Ambiguities matter when they change behavior.

Mere disagreement is usually noise.

Reality is not smooth.

Production systems are negotiated with time, cost, failure, and change.

Code is not static.

Code grows, bends, splits, merges, and dies.

Design for the next change, not for a frozen diagram.

Simplicity is not shallowness.

Completeness is not always responsibility.

Edge cases have diminishing returns.

Complexity compounds.

Rot compounds faster.

Prefer deletion over addition.

Prefer reuse over invention.

Prefer boring contracts over clever machinery.

Prefer the chosen guarantee over an imagined stronger one.

Functional programming is not the goal of the Erlang VM.

It is a means to reliable, concurrent, inspectable systems.

Purity is useful when it protects a boundary.

Purity is harmful when it becomes ceremony.

Processes are fault boundaries, not nouns.

Supervision is architecture, not decoration.

If no failure boundary changed, do not move the supervision tree.

Before changing code, write the cleanup plan.

Before adding code, ask what can be deleted.

Before inventing a pattern, search for the existing one.

Before criticizing a tradeoff, check whether it was already settled.

If it was settled, inspect inside it.

Do not relitigate it.

Working drafts may think out loud.

Shareable documents must not.

Remove scaffolding, TODO theater, abandoned alternatives, and meta-writing before committing docs.

### Scope fidelity

When a document says a tradeoff is final, evaluate consistency inside that tradeoff.

Do not argue for theoretical completeness unless the user asked for it.
Do not optimize for a perfect static design. This system will change.

A design that handles every imagined edge case today may become the source of tomorrow's rot.

Prefer the smallest correction that preserves the chosen direction.

If something looks risky, first ask:
- Is it actually inconsistent with the stated goal?
- Is it an omission inside the chosen design?
- Is it a contradiction against another explicit decision?
- Or am I merely disagreeing with the tradeoff?

Only the first three are useful by default. The fourth is noise unless explicitly requested.

### Reality bias

Real systems are uneven.

Do not assume the cleanest theoretical model is the responsible one.

A little duplication may be better than a premature abstraction.

A manual recovery path may be better than a complex automatic one.

A weaker guarantee may be better than code that nobody can safely change.

Prefer designs that remain understandable after six months of patches.

Prefer code that can be deleted.

Prefer behavior that can be explained to an operator.

Prefer guarantees that the system can actually keep.

## Subsystems

BullX is a single `:bullx` OTP application. Subsystems are placed on one of two tiers inside that application, decided by independence/coupling:

- **L1 — nested inside core** (`lib/bullx/<x>/`, modules `BullX.<X>.*`): tightly coupled to core; not a first-class concern on its own.
- **L2 — top-level namespace peer of core** (`lib/bullx_<x>/`, modules `BullX<X>.*`): first-class architectural concern, weakly coupled to core. Follows the same pattern Phoenix uses for `lib/bullx_web/` + `BullXWeb.*` — same mix project, same OTP app, just a sibling namespace at the top of `lib/`.

Escalation only happens on observed pressure. L1→L2 requires that the module is a first-class concern (parallel to Gateway / Web / Brain / AIAgent), not a core subcomponent.

| Subsystem | Tier | Path | Top-level module |
|---|---|---|---|
| **Gateway** | L2 | `lib/bullx_gateway/` | `BullXGateway` |
| **Brain** | L2 | `lib/bullx_brain/` | `BullXBrain` |
| **AIAgent** | L2 | `lib/bullx_ai_agent/` (or `lib/bullx_ai_agent.ex` — currently a single namespace file until the jido_ai fork lands) | `BullXAIAgent` |
| **Web / control plane** | L2 | `lib/bullx_web/` | `BullXWeb` |
| **Runtime** | L1 | `lib/bullx/runtime/` | `BullX.Runtime` |
| **Skills** | L1 | `lib/bullx/skills/` | `BullX.Skills` |

Subsystem summaries:

- **Gateway** (`lib/bullx_gateway/`, L2) — multi-transport ingress and egress. Normalizes inbound events from external sources (HTTP polling, subscribed WebSockets, webhooks, channel adapters like Feishu/Slack/Telegram) into internal signals, and dispatches outbound messages back to those destinations. Owns the `BullXGateway.Adapter` behaviour, signal types, delivery types (`BullXGateway.Delivery.*`), and the dedupe/control-plane store. Channel adapter implementations land as additional top-level namespaces (e.g. `lib/bullx_feishu/` → `BullXFeishu.*`) that implement `BullXGateway.Adapter`.
- **Runtime** (`lib/bullx/runtime/`, L1) — the long-lived process layer. Owns session processes, LLM/tool task pools, sub-agent supervision, and cron scheduling with exactly-once semantics across restarts.
- **AIAgent** (`lib/bullx_ai_agent.ex`, L2) — the AI Agent behavior layer. Prompt types, reasoning strategies (FSM / DAG / behavior tree), and decision logic. Forked from jido_ai v2.1.0 and substantially rewritten for BullX's needs, so BullX does not depend on `jido_ai` as a package.
- **Brain** (`lib/bullx_brain/`, L2) — persistent memory and knowledge graph. A typed ontology of objects, links, and properties forms the skeleton; `(observer, observed)`-keyed cortexes hold engrams (LLM-extracted reasoning traces at distinct inference levels). A background Dreamer process consolidates engrams, detects contradictions, and promotes abstraction level.
- **Skills** (`lib/bullx/skills/`, L1) — registry of preset and custom capabilities. Every skill is backed by a validated `Jido.Action`.
- **Control plane** (`lib/bullx_web/`, L2) — Phoenix app. Operator-facing web console (budgets, approvals, HITL queues, audit trails, observability) and the HTTP surface for the system.

### Directory semantics

- **`lib/bullx/`** — the `:bullx` app's core: `Application`, top-level `Supervisor`, `Repo`, `Config`, `Mailer`, plus L1 subsystems (`runtime/`, `skills/`).
- **`lib/bullx_<x>/`** — L2 subsystems: first-class concerns that live in the same `:bullx` app via top-level namespace. All share `mix.exs`, boot under the same `BullX.Application` supervision tree, and are indistinguishable from the outside world — the split is purely architectural naming, the same pattern as `lib/bullx_web/` ↔ `BullXWeb`.
- **`packages/<x>/`** — externally reusable mix projects, publishable to Hex (e.g. `packages/feishu_openapi/`). Reserved for libraries whose semantics do not depend on BullX; anything BullX-specific belongs in `lib/`.

Confirm which subsystem you are editing before applying the framework-specific rules below. The Elixir, Mix, Test, and Ecto rules apply everywhere. The Phoenix / LiveView / HEEx / Tailwind rules apply only to code under `lib/bullx_web`.

## Plan-first workflow

BullX implements features and fixes complex bugs through a plan-first process:

1. A human writes a plan in `rfcs/plans/` that specifies the full scope of the work — files to create or modify, expected module shapes, and acceptance criteria. If no plan exists, make the smallest viable plan inline before editing. Do not invent broad architecture for a narrow task.
2. Write a cleanup plan before modifying code.

   The cleanup plan must answer:

   - What can be deleted?

   - What existing utility or pattern can be reused?

   - What code path, process, schema, Action, Signal, or Directive is actually changing?

   - What invariant must remain true?

   - What command will verify the result?
3. A coding agent executes the plan. The plan is the source of truth; deviations require explicit justification.
4. The plan stays committed in the repo as a record of design intent.

In BullX, `rfcs/plans/` is more like design docs than traditional RFCs. They are expected to be more detailed and prescriptive than typical design docs, and they are the primary artifact for communicating design and implementation decisions. The plan-first process is designed to ensure alignment on scope and approach before coding begins, and to provide a clear reference for the coding agent.

## Review settled designs correctly

When reviewing an existing plan, RFC, architecture note, or user decision, distinguish four things:

1. Omission.
   Something required by the stated design is missing.

2. Contradiction.
   Two stated decisions cannot both be true.

3. Ambiguity.
   The code or document leaves multiple plausible interpretations.

4. Disagreement.
   You would have chosen a different tradeoff.

Report omissions, contradictions, and harmful ambiguities.

Do not report mere disagreement as if it were a defect.

Do not relitigate durability, consistency, latency, availability, purity, normalization, or abstraction choices that the human has already marked as deliberate.

## Jido ecosystem primer

BullX is built on top of three packages from the Jido Elixir agent ecosystem: `jido`, `jido_action`, and `jido_signal`. They are relatively new and their APIs are unlikely to be accurately represented in LLM training data — treat this section as authoritative, and consult the reference docs at `/Users/ding/Projects/jido/` for API-level detail. BullX does **not** depend on `jido_ai`; the `BullX.AIAgent` subsystem is forked from jido_ai v2.1.0 and rewritten in-tree.

### Terminology that is easy to get wrong

Several Jido terms collide with more general meanings that dominate LLM training data. Always resolve them to the Jido-specific sense inside this codebase.

- **Agent is not "AI agent" by default.** In Jido, an Agent is any autonomous, long-lived, message-driven entity — a cron-ticked data syncer, a stock-price watcher, a periodic cleanup task. No LLM is involved by default. AI-flavored agents are one specialization, layered on top via `jido_ai` (or, in BullX, via `BullX.AIAgent`). When the codebase says "Agent" without qualification, assume non-AI unless the surrounding context says otherwise.
- **Action is not an "LLM tool call".** An Action is a validated command that anything can invoke: direct code, a `Chain`, an Agent's `cmd/2`, or an LLM via `to_tool/0`. LLM-tool exposure is one usage of an Action, not its definition.
- **Signal is not a POSIX signal and not an ad-hoc message.** It is a CloudEvents 1.0.2 envelope with `id`, `source`, `type`, `time`, `data`, and extensions. Do not model it as a bare atom, a tuple, or a loose map.
- **Directive is inert data.** Returning `%Directive.Emit{...}` from `cmd/2` does not emit anything; the AgentServer runtime emits it later during directive execution. The purity of `cmd/2` is load-bearing — side-effecting APIs must never be called from inside it.
- **`cmd/2` vs `run/2`.** `cmd/2` is the Agent's pure state-transition function: `(agent, {action_module, params}) -> {agent, [directive]}`. `run/2` is the Action's execution callback: `(params, context) -> {:ok, result} | {:error, reason}`. Different layers, different purity contracts — do not mix them.
- **AgentServer** is a GenServer — the server side of Jido's Agent client/server split within a BEAM node. It is not an HTTP server, not a Phoenix endpoint, not a network-facing process.
- **Plugin** is a composition bundle (Actions, state, and signal routes merged into an Agent at definition time), not a WordPress/Rails-style event hook.
- **Jido instance** is application-level: one application typically hosts one instance, and that instance supervises many Agent processes. Do not conflate "instance" with "Agent process."
- **jido_ai is a layer, not a fork origin in the Hex sense.** In the public ecosystem, `jido_ai` is a separate package built on top of `jido`. BullX chose not to depend on that package; `BullX.AIAgent` instead takes jido_ai v2.1.0's source as a starting point and rewrites what it needs, in this repo.

### jido (Hex name `:jido`, sometimes called `jido_core`)

- **Agent** is an immutable struct plus a pure `cmd/2` function with signature `(agent, {action_module, params}) -> {agent, [directive]}`. The Agent has no process of its own — it is data and a decision function.
- **AgentServer** is the GenServer runtime that wraps an Agent: it receives signals, routes them to actions, calls `cmd/2`, and executes the returned directives.
- **Directive** is a declarative description of a side effect. Examples: `Emit` (publish a signal), `Spawn` (start a child agent), `Schedule` (deliver a message later), `Stop`. Business code returns directives; the runtime executes them — this is the key separation that keeps Agent logic pure and testable.
- `use Jido, otp_app: :my_app` creates a **Jido instance** module that, when added to a supervision tree, brings up a `Registry` (id → pid), a `DynamicSupervisor` for agent processes, a `Task.Supervisor` for agent-owned tasks, and a `RuntimeStore` ETS table for relationships. Each application owns its instance; there is no global singleton.
- **Plugin**, **Strategy**: composable extension mechanisms on top of an Agent. Strategies (Direct, FSM, ReAct, and custom) decide how an Agent processes input; Plugins bundle Actions + state + routes.

### jido_action (Hex `:jido_action`)

- **Action** is a validated command. `use Jido.Action` with `name`, `description`, input `schema`, `output_schema`, and a `run(params, context)` callback produces a module with compile-time validation, LLM tool-schema export (`to_tool/0`), and composition helpers.
- Actions are independently usable — no Agent is required. They can be chained (`Chain`), retried, compensated, and have their execution instrumented via telemetry.

### jido_signal (Hex `:jido_signal`)

- **Signal** is a CloudEvents 1.0.2 structured envelope: `id`, `source`, `type` (dot-qualified, e.g. `conversation.message.received`), `time`, `data`, plus custom extensions. Signals are the unit of communication between BullX subsystems.
- **Signal.Bus** is the pub/sub hub with trie-based wildcard routing (`user.*`, `audit.**`), optional persistence, and multiple dispatch adapters (PID, `Phoenix.PubSub`, HTTP webhook, named queues, ...). Typed routes can be combined across Agents, Plugins, and Strategies.

## Project guidelines

- Use `mix precommit` when you are done with all changes and fix any pending issues
- Use the already included `:req` (`Req`) library for HTTP requests
- Prefer deletion over addition. If the same behavior can be preserved by removing code, remove code.
- Reuse existing utilities and patterns first. Search before creating a new helper, module, behaviour, process, schema, or dependency.
- Do not add dependencies unless the user explicitly requests or approves them.
- Do not introduce a new abstraction for a single use. Wait for repeated pressure or a clearly named domain boundary.
- Do not optimize for the local patch at the cost of future change. Code is not static. It will move, split, merge, and be deleted.
- Keep public contracts boring. Prefer explicit structs, schemas, Actions, Signals, and Directives over loose maps and freeform strings.
- Keep process state reconstructible. Process-local state is ephemeral and must be safe to rebuild on restart.
- Verify outcomes before final claims. Do not say a bug is fixed, a feature works, or a migration is safe unless you ran the relevant command or clearly state what remains unverified.

## Cleanup and refactor rules
For cleanup or refactor work, write the cleanup plan before modifying code.

A cleanup plan must list:

- Dead code to delete.

- Duplicate logic to merge.

- Existing utilities or patterns to reuse.

- Tests or commands that prove behavior is preserved.

- Risks to supervision, persistence, message flow, or public contracts.

Prefer deleting obsolete code to wrapping it.

Prefer moving code to inventing code.

Prefer one clear boundary to many clever seams.

Do not keep compatibility shims unless there is a real caller.

Do not leave old names, old branches, old TODOs, or old comments behind after replacing behavior.

When a refactor touches OTP structure, state which failure boundary changed.

If no failure boundary changed, avoid changing the supervision tree.

## Shareable document hygiene
Working drafts may be messy.

Shareable documents must be clean.

Do not leave meta-writing scaffolding in committed docs:
- no "draft below"
- no "here is a polished version"
- no "I will now"
- no outline markers that are not part of the document
- no unresolved TODOs unless the document intentionally tracks work
- no duplicated alternatives unless the document is explicitly comparing alternatives

When writing README, RFC, plan, prompt, policy, or operator-facing documentation:
- Write the final artifact, not a transcript of how you got there.
- Remove internal reasoning markers.
- Remove abandoned headings.
- Resolve placeholders.
- Keep examples consistent with the current codebase.
- Prefer direct instructions over commentary about the instructions.

## Elixir

Use `elixir-coding` skills (./.agents/skills/elixir-coding/SKILL.md) when working in Elixir files.

## Phoenix subsystem (lib/bullx_web only)

> The following three sections — Phoenix v1.8, JS and CSS, UI/UX & design — apply only when editing code under `lib/bullx_web`.

Please use `phoenix-coding` skills (./.agents/skills/phoenix-coding/SKILL.md) when working in the Phoenix subsystem.

## Elixir Rust NIFs

We use `rustler` to build Rust NIFs for CPU-intensive tasks that require performance beyond what Elixir can provide. 

Please use `elixir-rust-nif-coding` skills (./.agents/skills/elixir-rust-nif-coding/SKILL.md) when working on Rust NIFs. 
