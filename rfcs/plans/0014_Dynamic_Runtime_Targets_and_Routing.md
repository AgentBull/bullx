# RFC 0014: Dynamic Runtime Targets and Inbound Routing

**Status**: Implementation plan  
**Author**: Boris Ding  
**Created**: 2026-04-30  
**Depends on**: RFC 0002, RFC 0003, RFC 0009, RFC 0013

## 1. TL;DR

This RFC adds the first runtime slice for database-defined BullX runtime targets
and database-defined inbound routing. It deliberately keeps the implementation
small:

1. **Dynamic runtime targets.** Add `runtime_targets`, where each row is a
   routeable Runtime target keyed directly by its operator-facing `key`. This
   RFC ships two target kinds: `agentic_chat_loop`, backed by BullXAIAgent's
   existing AgenticLoop runtime and RFC 0013 model aliases, and `blackhole`, a
   black-hole target for explicit route exclusions. The kind column is text plus
   writer validation, so later RFCs can add new target kind modules without
   changing the table shape.
2. **Dynamic inbound routes.** Add `runtime_inbound_routes`, compile rows
   into a `Jido.Signal.Router`, and resolve Gateway inbound signals to one
   runtime target. Route updates through the Runtime writer refresh the in-memory
   router without restarting the system.
3. **Built-in `main` fallback.** If the route table is empty or does not match
   an inbound signal, Runtime uses a code-owned fallback route pointing to the
   built-in `main` `agentic_chat_loop` target. A fresh BullX install can
   therefore receive a Feishu message and reply through Feishu after LLM
   provider setup.
4. **Live multi-turn chat for chat targets.** Runtime starts one live session
   process per `{target, adapter, channel_id, scope_id, thread_id}` key for
   `agentic_chat_loop` targets. That process keeps a minimal in-memory
   conversation context while it is alive, serializes turns, runs AgenticLoop,
   and sends the final answer to `reply_channel` through
   `BullXGateway.deliver/1`.
5. **Minimal prompt assembly only.** The AI prompt for this RFC is baseline
   system instructions plus one DB slot: `system_prompt.soul`. Memory, skills,
   context compression, final prompt/context assembly, and durable session
   reconstruction are not part of this RFC.

The core acceptance slice is intentionally concrete: with Feishu configured and
`:default` bound to an LLM provider, a user can message the BullX bot in Feishu,
receive an AI reply in Feishu, and continue the conversation for multiple turns
as long as the live session process has not idled out or restarted.

### 1.1 Cleanup plan

- **Dead code to delete**
  - None. Existing Gateway, Feishu, AIAgent, and LLM catalog code is reused.
  - Do not delete or rewrite `BullXAIAgent.Agent`; dynamic chat targets bypass
    its compile-time macro restrictions through a new runtime target kind module.
- **Duplicate logic to merge / patterns to reuse**
  - Reuse `BullXGateway.Signals.InboundReceived` and the fixed Gateway carrier
    type `com.agentbull.x.inbound.received`; do not introduce a second inbound
    envelope or change Gateway's signal contract.
  - Reuse `Jido.Signal.Router` for path matching, fixed route match functions,
    priority, and runtime route replacement.
  - Reuse `BullXGateway.Delivery` and `BullXGateway.deliver/1` for replies.
  - Reuse `BullXAIAgent.Reasoning.AgenticLoop`, `BullXAIAgent.Context`, and
    RFC 0013 `BullXAIAgent.ModelAliases` / LLM catalog resolution.
  - Reuse `BullX.Repo`, Ecto schemas, and PostgreSQL constraints for new
    persistent definitions.
- **Code paths / processes / schemas changing**
  - Add Runtime-owned schemas for target definitions and inbound routes.
  - Add a Runtime-owned route cache that compiles DB rows into a
    `Jido.Signal.Router`.
  - Add a Runtime inbound subscriber on `BullXGateway.SignalBus`.
  - Add a Runtime session registry, dynamic supervisor, and per-session GenServer
    for live AI chat turns.
  - Add `BullXAIAgent.Kind.AgenticChatLoop` as the runtime bridge from an
    `agentic_chat_loop` target to the existing AgenticLoop runner.
  - Add a Runtime-owned `blackhole` target kind that terminates matching inbound
    signals without creating a session or running fallback.
  - Modify `BullX.Runtime.Supervisor` to start the new Runtime children.
- **Invariants that must remain true**
  - Gateway remains transport-agnostic. Runtime consumes Gateway's canonical
    inbound signal and produces Gateway deliveries; Gateway does not know about
    runtime targets.
  - Route resolution always produces exactly one terminal target selection:
    highest-priority matching DB target, otherwise built-in `main`. The
    `blackhole` target is terminal and intentionally produces no chat turn.
  - Route matching is stored as simple nullable match columns, not an open-ended
    predicate language and not executable Elixir strings.
  - DB routes never outrank the code fallback by using negative priority. DB
    route priority is `0..100`; the built-in fallback is priority `-100`.
  - The live conversation context is process-local and not durable. Restart or
    idle timeout loses it. This is a deliberate v1 boundary, not a persistence
    guarantee.
  - Target config changes affect the next turn. An in-flight turn is not
    interrupted or rewritten.
  - The first implementation exposes no skills, no tool catalog UI, no
    DB-synthesized Action code, no subagent delegation, no scheduled tasks, no
    route/target disable switch, and no session persistence.
- **Verification commands**
  - `mix test test/bullx/runtime/targets`
  - `mix test test/bullx_ai_agent/kind/agentic_chat_loop_test.exs`
  - `mix test test/bullx_gateway test/bullx_feishu`
  - `bun precommit`

## 2. Context

The draft in
[`internals/design-docs-drafts/dynamic-agents-and-routing.md`](../../internals/design-docs-drafts/dynamic-agents-and-routing.md)
sets the correct direction: dynamic routeable definitions, dynamic route rows,
route-table semantics, and a `main` fallback. The formal plan tightens that
draft around the current codebase and the clarified v1 scope.

Important existing facts:

- Gateway publishes a single inbound carrier signal:
  `com.agentbull.x.inbound.received`. The concrete event type/name lives in
  `signal.data["event"]`; adapter/channel identity lives in CloudEvents
  extensions. This RFC does not change that contract.
- `BullXAIAgent.Agent` is compile-time oriented: tools, model, and system prompt
  are macro options. Dynamic DB rows therefore should not create one module per
  row or force every runtime target through that macro.
- `BullXAIAgent.Reasoning.AgenticLoop` already has a task-based runtime API and
  a minimal `BullXAIAgent.Context` implementation. For a no-tools MVP chat path,
  that is enough to maintain live multi-turn context inside a Runtime session
  process.
- RFC 0013 makes model endpoints database-backed through a provider catalog and
  fixed alias set. Dynamic target config should store either a model alias or a
  provider catalog name, never raw provider secrets.
- `Jido.Signal.Router` already provides wildcard path matching, predicate
  functions, priority ordering, and runtime add/remove behavior. BullX routing is
  a constrained use of that router, not a separate routing engine.

External background read for user-context calibration:

- OpenClaw presents the integrated product surface BullX will eventually cover:
  messaging channels, dashboard, model routing, skills/plugins, memory, cron,
  local-first operation, and Feishu/Lark integration.
  <https://grokipedia.com/page/OpenClaw>
- Hermes Agent separates UI entrypoints, core agent orchestration, execution
  backends, gateway mode, provider runtime resolution, prompt/context handling,
  tools, memory, and scheduled tasks.
  <https://deepwiki.com/NousResearch/hermes-agent>

Those systems are useful references for the product background, but this RFC
does not copy their full surface. BullX's first slice is the routing and live
chat backbone only.

## 3. Scope

### 3.1 In scope

- Add PostgreSQL schema and Ecto schemas for Runtime target definitions and
  Runtime inbound routes.
- Add a Runtime writer API for creating/updating/deleting targets and routes.
- Add an in-memory, reconstructible route cache that loads from PostgreSQL on
  boot and refreshes on writer calls.
- Compile route rows into `Jido.Signal.Router` routes.
- Add lightweight route match columns covering the routing dimensions needed for
  v1.
- Add Runtime inbound handling from `BullXGateway.SignalBus` to route resolution
  to target execution.
- Add live session processes keyed by `{target, adapter, channel_id, scope_id,
  thread_id}` for `agentic_chat_loop` targets.
- Add `BullXAIAgent.Kind.AgenticChatLoop` for minimal no-tools chat turns.
- Add a `blackhole` target kind for explicit deny/exclusion routes.
- Send final AI answers back through `BullXGateway.deliver/1` when the inbound
  signal has a `reply_channel`.
- Support live multi-turn conversation while the session process remains alive.
- Add tests for route matching, fallback behavior, blackhole target termination,
  cache refresh, session key derivation, AgenticLoop request construction, and
  Gateway delivery enqueue.

### 3.2 Out of scope

- Scheduled tasks, cron-triggered targets, reminders, or background jobs.
- Session persistence, restart recovery of chat history, cross-process session
  migration, or durable thread storage.
- Full final prompt/context assembly, memory injection, retrieved facts,
  prompt-cache optimization beyond keeping the baseline system prompt stable, or
  context compression.
- Skills, skill discovery, custom tool catalogs, DB-synthesized Actions, or
  arbitrary Elixir code loaded from the database.
- Subagents, delegation, parent/child agent hierarchy, or inter-agent routing.
- WorkflowExecutor / n8n-style graph execution. The data model is kind-aware so
  this can be added later, but this RFC only executes the `agentic_chat_loop`
  and `blackhole` target kinds.
- Phoenix Web UI for managing targets/routes. This RFC adds Runtime writer APIs
  and tests; a Web control-plane surface is a follow-up.
- Multi-tenant isolation. BullX has no tenant concept in the current design.
- Route fan-out to multiple targets for one inbound signal. First-match-wins is
  the only target selection behavior.
- Streaming partial replies to Feishu. The v1 chat path sends the final answer.

## 4. Subsystem Placement

Dynamic routing, target execution, and live sessions belong to **Runtime**:

```text
lib/bullx/runtime/targets/
test/bullx/runtime/targets/
```

Runtime owns the process boundary because it already owns sessions, LLM/tool
task pools, sub-agent supervision, and scheduling in the BullX subsystem map.
Gateway remains the ingress/egress boundary. AIAgent remains the AI behavior
library.

AIAgent gains only the chat target bridge:

```text
lib/bullx_ai_agent/kind/agentic_chat_loop.ex
test/bullx_ai_agent/kind/agentic_chat_loop_test.exs
```

No new top-level subsystem is introduced.

## 5. Data Model

### 5.1 Kind extensibility

`runtime_targets.kind` is stored as text, not as a PostgreSQL enum. This is a
deliberate exception to the usual closed-set enum preference: target kinds are a
Runtime extension point, and adding a new kind should require adding a kind
module and writer validation, not rewriting the table shape.

The database enforces only identifier shape:

```sql
CHECK (kind ~ '^[a-z][a-z0-9_]*$')
```

The Runtime writer owns the supported-kind registry. In this RFC the registry
contains exactly two kinds:

```elixir
%{
  "agentic_chat_loop" => BullXAIAgent.Kind.AgenticChatLoop,
  "blackhole" => BullX.Runtime.Targets.Kind.Blackhole
}
```

### 5.2 Runtime targets vs Jido terms

`runtime_targets` is a BullX Runtime routing abstraction. It is deliberately not
renamed to `actions`, and it is not a Jido Agent table.

| Concept | Meaning in this RFC |
| --- | --- |
| `runtime_target` | A persisted Runtime target selected by inbound routing. It owns operator-facing identity, `kind`, and kind-specific config. |
| Jido Action | A compile-time validated command module with `run/2`. This RFC does not store arbitrary Action modules in the database and does not expose a DB Action registry. |
| Jido Agent | An immutable data structure with pure `cmd/2`; `AgentServer` is its OTP runtime. This RFC does not create dynamic Jido Agent modules or one AgentServer per DB row. |
| AI agent / AgenticLoop | BullX's AI behavior layer. `agentic_chat_loop` is one Runtime target kind that uses the existing AgenticLoop runner. |

This boundary prevents later semantic drift:

- Routes match signals and select a `runtime_target`.
- Target kind modules execute the selected target.
- A Runtime target is not necessarily conversational and not necessarily AI.
  Only `agentic_chat_loop` is a chat target in this RFC.
- The route table does not store `route_action`, `decision`, or arbitrary
  module names. Execution semantics live behind the selected target kind.
- Future RFCs may add target kinds backed by code-owned Jido Actions, code-owned
  Jido Agents / AgentServers, or WorkflowExecutor graphs. Routes still select
  Runtime targets, not arbitrary Action modules, Agent modules, or workflow
  nodes.
- The `blackhole` target is a black-hole Runtime target. It may be implemented by
  a small code-owned function or Action, but it is not user-configurable Jido
  Action dispatch.

### 5.3 `runtime_targets`

| Column | Type | Constraints |
| --- | --- | --- |
| `key` | `text` | primary key, stable operator-facing id such as `main` or `finance_bot` |
| `kind` | `text` | not null, writer-validated supported kind |
| `name` | `text` | not null |
| `description` | `text` | nullable |
| `config` | `jsonb` | not null, default `{}` |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | not null |

`config` is validated in the Runtime writer according to `kind`. The database
only enforces JSON object shape:

```sql
CHECK (jsonb_typeof(config) = 'object')
```

There is no `status` column in this RFC. Targets cannot be disabled yet. Removing
or changing routes is the only supported way to stop routing new inbound turns
to a configured target.

The key `main` is reserved for the fallback chat target. The writer rejects
`key = "main"` unless `kind = "agentic_chat_loop"`.

#### `agentic_chat_loop` config shape

The first writer accepts this shape:

```json
{
  "model": "default",
  "system_prompt": {
    "soul": "You are the main BullX assistant."
  },
  "agentic_chat_loop": {
    "max_iterations": 4,
    "max_tokens": 4096
  }
}
```

Rules:

- `model` is required. It resolves either to one of RFC 0013's model aliases
  (`default`, `fast`, `heavy`, `compression`) or to an exact
  `llm_providers.name` provider catalog row. Alias names are reserved; when the
  string is one of the four aliases it is resolved as an alias.
- `system_prompt.soul` is the only DB-controlled prompt slot in this RFC. It is
  required and must be a non-empty string after trimming. It is appended after
  the BullX baseline system instructions. It cannot replace the baseline.
- `agentic_chat_loop.max_iterations` defaults to `4` for chat MVP. Operators may
  raise it, but there are no tools in this RFC, so high values are usually
  wasted. The value must be a positive integer.
- `agentic_chat_loop.max_tokens` defaults to `4096` and must be a positive
  integer.
- The writer rejects unknown top-level config keys and unknown nested keys under
  `system_prompt` and `agentic_chat_loop`.
- The AgenticLoop request always runs in streaming mode internally. Runtime
  consumes the stream and sends only the final answer through Gateway; outbound
  Feishu partial streaming is still out of scope.

#### `blackhole` config shape

The `blackhole` target accepts only an empty config object:

```json
{}
```

A `blackhole` target is terminal:

- It does not create or touch a live session.
- It does not call AIAgent, Jido Agent, or arbitrary Jido Action modules.
- It does not enqueue a Gateway delivery.
- It does not fall through to the built-in `main` fallback.
- It emits safe telemetry so operators can explain why a signal was dropped.

### 5.4 `runtime_inbound_routes`

| Column | Type | Constraints |
| --- | --- | --- |
| `key` | `text` | primary key, stable operator-facing id |
| `name` | `text` | not null |
| `priority` | `integer` | not null, default `0`, `CHECK (priority >= 0 AND priority <= 100)` |
| `signal_pattern` | `text` | not null, default `com.agentbull.x.inbound.**` |
| `adapter` | `text` | nullable exact match against `extensions["bullx_channel_adapter"]` |
| `channel_id` | `text` | nullable exact match against `extensions["bullx_channel_id"]` |
| `scope_id` | `text` | nullable exact match against `data["scope_id"]` |
| `thread_id` | `text` | nullable exact match against non-null `data["thread_id"]` |
| `actor_id` | `text` | nullable exact match against `data["actor"]["id"]` |
| `event_type` | `text` | nullable exact match against `data["event"]["type"]` |
| `event_name` | `text` | nullable exact match against `data["event"]["name"]` |
| `event_name_prefix` | `text` | nullable prefix match against `data["event"]["name"]` |
| `target_key` | `text` | not null, FK to `runtime_targets(key) ON DELETE RESTRICT` |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | not null |

Nullable match columns are wildcards. A route with only `target_key` set
matches every inbound signal covered by `signal_pattern`.

`thread_id = NULL` means wildcard. This RFC does not add a separate sentinel for
"only signals without a thread"; use `scope_id` for that common case.

`event_name` and `event_name_prefix` are mutually exclusive:

```sql
CHECK (event_name IS NULL OR event_name_prefix IS NULL)
```

There is no `status` column in this RFC. To stop using a route, delete it or
replace it through the writer.

The fallback route is not stored in this table. It is code-owned:

```text
pattern:  com.agentbull.x.inbound.**
match:    all wildcard
target:   builtin main
priority: -100
```

## 6. Route Matching

Route matching stays intentionally narrow. The common user stories need:

- "all Feishu inbound goes to this target" -> set `adapter = "feishu"`.
- "this Feishu group goes to this target" -> set `adapter` + `scope_id`.
- "this actor goes to this target" -> set `adapter` + `actor_id`.
- "slash commands or adapter event families go to this target" -> set
  `event_type`, `event_name`, or `event_name_prefix`.
- "everything except this noisy source" -> add a higher-priority route to an
  `blackhole` target for the excluded source, then keep the broader route to the
  chat target.

The first implementation does not need `neq`, arbitrary `in` lists, nested
`event.data` matching, or Cedar expressions. If an operator needs a small
allowlist, they create multiple routes to chat targets. If they need a small
denylist, they create higher-priority routes to a `blackhole` target. If those
rows become noisy, that is the pressure for a later predicate RFC.

Runtime compiles each row into a `Jido.Signal.Router` entry:

```elixir
{
  route.signal_pattern,
  fn signal -> BullX.Runtime.Targets.Router.match_route?(route, signal) end,
  {:runtime_target_route, route.key, route.target_key},
  route.priority
}
```

`match_route?/2` is ordinary Elixir code over the route struct's fixed columns.
The database never stores executable code and never stores an open-ended
predicate AST.

When multiple rows match the same signal, Runtime chooses deterministically:

1. Higher `priority`.
2. Higher specificity, measured as the number of non-null match columns, with
   `event_name` more specific than `event_name_prefix`.
3. Lexicographically smaller route `key`.

This preserves route-table behavior without making the data model more general
than current use cases require.

The selected route's target kind is terminal. A selected `blackhole` target stops
processing; Runtime must not continue to a lower-priority route or to the
built-in `main` fallback.

## 7. Runtime Design

### 7.1 Supervision tree

`BullX.Runtime.Supervisor` gains:

```text
BullX.Runtime.Targets.Cache
BullX.Runtime.Targets.SessionRegistry
BullX.Runtime.Targets.SessionSupervisor
BullX.Runtime.Targets.Ingress
```

`Cache` starts before `Ingress` so inbound routing is ready before Gateway
messages are consumed. `SessionSupervisor` is a `DynamicSupervisor`.

No Gateway supervision boundary changes. No AIAgent top-level supervisor changes.
`BullX.Application` must keep `BullX.Runtime.Supervisor` before
`BullXGateway.AdapterSupervisor` so adapters do not publish inbound signals
before Runtime has subscribed.

### 7.2 Modules

Create:

```text
lib/bullx/runtime/targets.ex
lib/bullx/runtime/targets/target.ex
lib/bullx/runtime/targets/inbound_route.ex
lib/bullx/runtime/targets/writer.ex
lib/bullx/runtime/targets/cache.ex
lib/bullx/runtime/targets/router.ex
lib/bullx/runtime/targets/executor.ex
lib/bullx/runtime/targets/ingress.ex
lib/bullx/runtime/targets/kind/blackhole.ex
lib/bullx/runtime/targets/session_key.ex
lib/bullx/runtime/targets/session_registry.ex
lib/bullx/runtime/targets/session_supervisor.ex
lib/bullx/runtime/targets/session.ex
lib/bullx_ai_agent/kind/agentic_chat_loop.ex
```

Responsibilities:

- `BullX.Runtime.Targets` is the public read/dispatch facade.
- `Target` and `InboundRoute` are Ecto schemas.
- `Writer` is the only supported write path. It validates target configs and
  route match rows, writes PostgreSQL, and refreshes `Cache`.
- `Cache` owns ETS tables and a compiled `Jido.Signal.Router`.
- `Router` converts route rows into router entries and resolves a signal to one
  target. It also owns fixed-column route matching.
- `Executor` dispatches the resolved target through the code-owned kind
  registry. It must not derive module names from DB strings.
- `Ingress` subscribes to `BullXGateway.SignalBus` and dispatches inbound signals.
- `SessionKey` derives stable live-session keys.
- `Session` owns the live conversation context and one-at-a-time turn execution.
  It does not cache target config across turns.
- `BullXAIAgent.Kind.AgenticChatLoop` builds the minimal AgenticLoop config and runs
  one chat turn.
- `BullX.Runtime.Targets.Kind.Blackhole` implements the terminal black-hole target.

### 7.3 Startup and cache refresh

On boot:

1. `Cache` loads `runtime_targets` and `runtime_inbound_routes`.
2. `Cache` validates and compiles routes into `Jido.Signal.Router`.
3. `Ingress` subscribes to `BullXGateway.SignalBus` for
   `com.agentbull.x.inbound.**`.

On writer calls:

1. Database write succeeds.
2. `Cache.refresh_all/0` rebuilds the route table.
3. New inbound turns see the new config. Existing in-flight turns continue.

Direct SQL edits are not a supported live-update path in this RFC. A later
control-plane RFC can add PostgreSQL notifications if external writers become a
real requirement.

## 8. Inbound Flow

```text
Feishu adapter
  -> BullXGateway.publish_inbound/1
  -> Jido.Signal.Bus publish: com.agentbull.x.inbound.received
  -> BullX.Runtime.Targets.Ingress receives signal
  -> BullX.Runtime.Targets.Router resolves route and target
  -> BullX.Runtime.Targets.Executor executes target kind
       agentic_chat_loop:
         -> SessionSupervisor ensures session
         -> Session serializes turn
         -> BullXAIAgent.Kind.AgenticChatLoop runs AgenticLoop
         -> BullXGateway.deliver/1 sends final answer through reply_channel
       blackhole:
         -> emit telemetry and stop
```

### 8.1 Route resolution

`Router.resolve(signal)` returns:

```elixir
{:ok, %{source: :db_route, route: route, target: target}}
{:ok, %{source: :fallback, route: :main, target: builtin_main_target}}
{:error, reason}
```

Normal no-match returns the fallback. Errors are reserved for invalid runtime
state such as a corrupt cache or unavailable built-in main profile.

All routes returned by `Jido.Signal.Router.route/2` are candidates. BullX then
applies the priority/specificity/key ordering from §6 and uses the first
candidate after that ordering. Multi-match fan-out is not implemented.

If the returned target has `kind = "blackhole"`, Runtime records the blackhole
result and stops. Fallback is only for no-match, never for a blackholed match.

### 8.2 Session key

The session key is:

```elixir
{
  target_key,
  adapter,
  channel_id,
  scope_id,
  thread_id || "__default_thread__"
}
```

Consequences:

- Two chat targets never share live conversation context accidentally.
- The same Feishu chat/thread keeps multi-turn context while routed to the same
  chat target.
- Changing route rules can move future messages to another target and therefore
  another live context. That is acceptable in v1 because session persistence and
  route migration semantics are deferred.
- `blackhole` targets do not use session keys.
- Each turn carries the target profile resolved for that signal. A live session
  keeps conversation context only; it uses the supplied target profile for the
  current turn so target config changes affect the next queued turn.
- A session processes one turn at a time in FIFO order. A new inbound signal does
  not interrupt an in-flight AgenticLoop run.

Chat session processes have a code-owned idle timeout of 30 minutes. Each
accepted turn resets the timeout. On timeout, the session stops and emits
`[:bullx, :runtime, :targets, :session_stopped]`. This timeout is not
DB-configurable in this RFC.

### 8.3 Text extraction

`Session` converts Gateway `content` blocks into the user text passed to
AgenticLoop:

1. Concatenate `text` blocks in order.
2. For non-text blocks, use `body["fallback_text"]` when present.
3. If no usable text exists, skip the turn and emit telemetry. The RFC does not
   add multimodal LLM input.

### 8.4 Reply delivery

If `signal.data["reply_channel"]` is present, `Session` sends:

```elixir
%BullXGateway.Delivery{
  id: BullX.Ext.gen_uuid_v7(),
  op: :send,
  channel: {reply_channel["adapter"], reply_channel["channel_id"]},
  scope_id: reply_channel["scope_id"],
  thread_id: reply_channel["thread_id"],
  reply_to_external_id: signal.data["reply_to_external_id"],
  caused_by_signal_id: signal.id,
  content: %BullXGateway.Delivery.Content{
    kind: :text,
    body: %{"text" => final_answer}
  },
  extensions: %{
    "bullx_runtime_target" => target_key,
    "bullx_runtime_route" => route_key_or_main
  }
}
```

If the signal is not duplex or has no `reply_channel`, Runtime runs no reply
delivery for this RFC.

## 9. `agentic_chat_loop` Target Kind

`BullXAIAgent.Kind.AgenticChatLoop` is a thin runtime bridge, not a new framework.

Input:

```elixir
%{
  target: target_profile_or_builtin_main,
  context: %BullXAIAgent.Context{},
  user_text: "hello",
  refs: %{signal_id: "...", route_key: "..."}
}
```

Output:

```elixir
{:ok, %{answer: String.t(), context: %BullXAIAgent.Context{}, usage: map(), trace: list()}}
{:error, reason}
```

For v1 no-tools chat:

1. Build a minimal system prompt from baseline + `system_prompt.soul`.
2. Resolve the configured `model` as an alias or direct provider catalog name.
3. Append the user text to the live context.
4. Run `BullXAIAgent.Reasoning.AgenticLoop` with `tools: %{}`.
5. Append the final answer to the live context.
6. Return final answer and updated context.

The kind module must not read Gateway structs directly and must not deliver
messages. Runtime owns transport concerns.

## 10. `blackhole` Target Kind

`BullX.Runtime.Targets.Kind.Blackhole` is a terminal black-hole target for
explicit route exclusions. It exists so route matching can stay pure:

```text
signal -> matching route -> target
```

`blackhole` has no prompt, model, session, memory, skills, or reply behavior. Its
execution result is:

```elixir
{:ok, %{blackholed: true}}
```

Runtime records route/target telemetry and returns. It must not call
`BullXAIAgent.Kind.AgenticChatLoop`, `BullXGateway.deliver/1`, a user-selected
Jido Action module, or the fallback `main` target.

## 11. Prompt Boundary

This RFC uses a deliberately small system prompt shape:

```text
<BullX baseline AI assistant instructions>

<system_prompt.soul from target config>
```

Rules:

- `system_prompt.soul` is required for every `agentic_chat_loop` target. It
  appends to the baseline; it does not replace it.
- No memory, skill manifest, retrieved facts, prior errors, or compression
  summaries are injected.
- `BullXAIAgent.PromptBuilder` remains available but is not expanded into a full
  prompt architecture by this RFC.
- The baseline system prompt should stay stable across turns. Per-turn user text
  and live context are message history, not system prompt mutations.

## 12. Built-in Main Target

Runtime owns a code-defined fallback profile:

```text
DEFAULT_SOUL_MD =
  "You are BullX Agent, an AI assistant by agentbull.com. "
  "You assist users with a wide range of tasks and execute actions via your tools.\n\n"
  "Personality: ENTJ — decisive, strategic, direct.\n\n"
  "Reasoning:\n"
  "- Reason from first principles. Treat mainstream consensus as one data point, not the answer.\n"
  "- Start without a presupposed position. Deduce and induce from fundamentals, "
  "then commit to the highest-probability conclusion as your stance.\n"
  "- Bias, when earned through reasoning, is a form of scarce taste.\n\n"
  "Interaction:\n"
  "- When the request is ambiguous, ask one targeted clarifying question before acting.\n"
  "- For tradeoffs, present the options, give a recommendation with reasoning, "
  "and let the user decide.\n"
  "- Be targeted and efficient. Match response length to question complexity."
```

```elixir
%{
  key: "main",
  kind: "agentic_chat_loop",
  name: "Main AI Agent",
  config: %{
    "model" => "default",
    "system_prompt" => %{
      "soul" => DEFAULT_SOUL_MD
    },
    "agentic_chat_loop" => %{
      "max_iterations" => 4,
      "max_tokens" => 4096
    }
  }
}
```

If a DB target with `key = "main"` exists, Runtime may use it for the fallback
target. If no such row exists, the code-defined profile is used. This keeps a
fresh install usable while allowing the operator to customize main later through
the same target writer.

DB routes may only reference persisted `runtime_targets` rows. The code-owned
fallback `main` target is not addressable from `runtime_inbound_routes` unless
an operator creates a persisted `runtime_targets.key = "main"` row.

## 13. Telemetry

Add telemetry events:

```text
[:bullx, :runtime, :targets, :route_resolved]
[:bullx, :runtime, :targets, :target_blackholed]
[:bullx, :runtime, :targets, :route_skipped]
[:bullx, :runtime, :targets, :session_started]
[:bullx, :runtime, :targets, :session_stopped]
[:bullx, :runtime, :targets, :turn_started]
[:bullx, :runtime, :targets, :turn_completed]
[:bullx, :runtime, :targets, :turn_failed]
[:bullx, :runtime, :targets, :reply_enqueued]
[:bullx, :runtime, :targets, :reply_failed]
```

Metadata must be safe to log:

- target key
- target kind
- route key or `main`
- adapter
- channel id
- scope id
- thread id
- signal id
- failure kind

Do not emit user message text, assistant output, API keys, or raw provider
payloads in telemetry metadata.

## 14. Tests

Add focused tests:

```text
test/bullx/runtime/targets/target_test.exs
test/bullx/runtime/targets/inbound_route_test.exs
test/bullx/runtime/targets/router_test.exs
test/bullx/runtime/targets/cache_test.exs
test/bullx/runtime/targets/executor_test.exs
test/bullx/runtime/targets/session_key_test.exs
test/bullx/runtime/targets/session_test.exs
test/bullx/runtime/targets/ingress_test.exs
test/bullx/runtime/targets/kind/blackhole_test.exs
test/bullx_ai_agent/kind/agentic_chat_loop_test.exs
```

Required coverage:

- Text primary keys for `runtime_targets.key` and `runtime_inbound_routes.key`.
- Target kind writer validation rejects unknown kind strings.
- Writer rejects `key = "main"` for non-`agentic_chat_loop` target kinds.
- Writer rejects `agentic_chat_loop` targets with missing or blank
  `system_prompt.soul`.
- Built-in `main` fallback uses code-owned `DEFAULT_SOUL_MD` when no persisted
  `runtime_targets.key = "main"` row exists.
- DB check constraints reject malformed kind strings and route rows with both
  `event_name` and `event_name_prefix`.
- Route matching covers adapter, channel, scope, thread, actor id, event type,
  event name, and event name prefix.
- Router priority and specificity choose the intended DB route above fallback.
- A high-priority route to a `blackhole` target terminates processing without
  falling through to lower-priority routes or fallback.
- Empty DB resolves to built-in `main`.
- Writer refreshes the cache after successful writes.
- Session key derivation is stable and includes target identity.
- Session serializes two turns and sends the second LLM request with prior live
  context.
- Updating a target's config changes the next turn for an existing live session
  without losing that session's live context.
- Session idle timeout stops an inactive chat session and a later turn starts a
  fresh live context.
- Ingress enqueues a Gateway delivery for duplex inbound messages.
- Non-duplex inbound signals do not enqueue a reply.

## 15. Acceptance Criteria

This RFC is complete when:

1. A fresh database with no `runtime_targets` or `runtime_inbound_routes` still
   routes inbound chat messages to built-in `main`.
2. With Feishu configured and RFC 0013 `:default` bound to a working provider,
   sending a text message to the Feishu bot produces a text reply in the same
   Feishu scope/thread.
3. Sending a follow-up message in the same Feishu scope/thread reaches the same
   live session process and includes prior live context in the LLM request.
4. Creating a DB `agentic_chat_loop` target plus a higher-priority route changes
   the next matching inbound turn without restarting the VM.
5. Deleting that route makes the next matching inbound turn fall back to `main`
   without restarting the VM.
6. Creating a DB `blackhole` target plus a higher-priority route suppresses the next
   matching inbound signal without creating a session, sending a reply, or
   falling back to `main`.
7. Route matching is fixed-column data; there is no `Code.eval_string/1`,
   arbitrary module creation, open-ended predicate AST, or DB-stored executable
   code in the routing path.
8. Runtime sends replies only through `BullXGateway.deliver/1`; no adapter module
   is called directly from Runtime.
9. No session persistence table, scheduled task table, subagent table, or custom
   action table is introduced by this RFC.
10. All verification commands in §1.1 pass.

## 16. Follow-up RFCs

These are intentionally not hidden inside this implementation:

- Durable session/thread persistence and restart reconstruction.
- Full prompt/context assembly, including memory, facts, skill manifests,
  retrieved context, and context compression.
- Skills and DB/action registry work, including any safe custom Action story.
- WorkflowExecutor for non-LLM graph-shaped targets.
- Scheduled tasks / cron-triggered targets.
- Subagents and delegation tools.
- Phoenix Web UI for managing targets, routes, dry-runs, and prompt previews.
- PostgreSQL notification support for external writers.

Each follow-up should preserve the route and target-definition contracts added by
this RFC unless it explicitly supersedes them.
