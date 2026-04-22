# RFC 0002: Gateway Inbound + ControlPlane

- **Author**: Boris Ding
- **Created**: 2026-04-22
- **Supersedes**: `rfcs/drafts/Gateway.md` (jointly with RFC 0003)

## 1. TL;DR

BullX Gateway is the OTP-based, durable ingress and egress layer for external messaging. The Gateway answers exactly two questions:

1. *"Something happened in the outside world; how does it become an internal BullX input signal?"*
2. *"Runtime wants to send something outwards; how does it reach the right external channel?"*

This RFC owns the **inbound carrier path** and the **ControlPlane** that durably backs it. The matching egress effects path — `Dispatcher`, `ScopeWorker`, retry / DLQ / replay, outbound dedupe — is owned by RFC 0003. Both RFCs share a single supervision tree, a single ControlPlane, a single content shape, and a single policy pipeline.

Key inbound design:

1. **Single inbound carrier with `event_category`.** Every inbound event is published as `signal.type = "com.agentbull.x.inbound.received"`. Gateway owns a 7-value canonical classification axis (`data.event_category`) — `message` / `message_edited` / `message_recalled` / `reaction` / `action` / `slash_command` / `trigger` — and derives a `data.duplex` boolean from it (six chat-style categories are duplex, `trigger` is not).
2. **Dual projection contract.** Each inbound signal carries both `agent_text` (for LLM consumption) and `adapter_event` (for machine routing / tool calls). Adapters always produce both; Gateway never invents one from the other.
3. **Adapter-owned event model + Gateway-owned carrier.** Gateway Core models the carrier and the canonical category; adapters model the domain event (`adapter_event.type` such as `feishu.message.posted`, `github.issue.opened`). Gateway does not enumerate, validate, or interpret the adapter event's domain fields.
4. **Durable carrier.** Inbound events are written to PostgreSQL (`BullX.Repo`) before adapters acknowledge external sources. The two inbound tables (`gateway_trigger_records`, `gateway_dedupe_seen`) are `UNLOGGED` because their loss is recoverable (external sources will retry, dedupe rebuilds from ETS hot cache rehydration). The DLQ table introduced by RFC 0003 is the only `LOGGED` table in the Gateway schema.
5. **Policy pipeline.** Gateway exposes pluggable `Gating`, `Moderation`, `Security` behaviours, modelled after `jido_messaging`. Defaults are empty. The pipeline order (`Security → Dedupe → Gating → Moderation → durable write → Bus publish`) is fixed by Gateway; the modules are supplied by the application.
6. **Flat scope model.** Gateway does not introduce `%Room{}` / `%Participant{}` / `%Thread{}` / `%RoomBinding{}` / `%RoutingPolicy{}`. The flat `{channel, scope_id, thread_id, actor + app_user_id, refs}` shape covers every IM / webhook scenario examined; chat-business aggregation is Runtime's job.

The egress half is summarised at the boundary (see RFC 0003) and only as much as this document needs to define the supervision tree, the `Adapter` behaviour, the Store callbacks, and the policy pipeline.

### 1.1 Cleanup plan

- **Dead code to delete**
  - Delete the placeholder `BullXGateway.CoreSupervisor` once `BullXGateway.CoreSupervisor` and `BullXGateway.AdapterSupervisor` are wired into `BullX.Application`.
  - Delete the old "Gateway boots with zero children" application test assumption; Gateway will now own concrete infrastructure children.
- **Duplicate logic to merge / patterns to reuse**
  - Reuse the existing subsystem supervisor pattern already used by `BullX.Config.Supervisor`, `BullX.Runtime.Supervisor`, `BullXBrain.Supervisor`, and `BullX.Skills.Supervisor`.
  - Reuse `BullX.Repo` + Ecto sandbox for all durable Gateway tests; do not add an ETS-only store variant.
  - Reuse `Jido.Signal` / `Jido.Signal.Bus` directly for the carrier instead of inventing a BullX-local signal envelope or bus abstraction.
- **Actual code paths / processes / schemas changing**
  - Add the inbound Gateway runtime path: `BullX.Gateway.publish_inbound/1` -> `InboundReceived` -> `Security` -> `Deduper` -> `Gating` -> `Moderation` -> `ControlPlane.Store.Postgres` -> `Jido.Signal.Bus.publish/2`.
  - Replace the empty Gateway supervisor with `CoreSupervisor` + `AdapterSupervisor` and move application startup order to `Repo -> Config -> Gateway.CoreSupervisor -> Skills -> Brain -> Runtime -> Gateway.AdapterSupervisor -> Endpoint`.
  - Add the inbound durable schemas `gateway_trigger_records` and `gateway_dedupe_seen` plus their Ecto wrappers.
- **Invariants that must remain true**
  - Gateway Core still must not model business-domain events or parse `adapter_event.data`.
  - Inbound dedupe is `(source, id)` based and `mark_seen` happens only after Bus publish succeeds.
  - `Gateway` code must stay independent of `Plug.Conn`; only `Webhook.RawBodyReader` may touch Plug types.
  - The final published inbound signal must be JSON-neutral, string-keyed, and always carry both `agent_text` and `adapter_event`.
- **Verification commands**
  - `mix test test/bullx/application_test.exs test/bullx_gateway`
  - `mix precommit`

## 2. Position and boundaries

### 2.1 What Gateway Core does

1. Hosts `BullXGateway.SignalBus` (a `Jido.Signal.Bus` instance).
2. Provides `BullX.Gateway.publish_inbound/1`: an adapter constructs one of the seven `BullXGateway.Inputs.*` canonical structs, hands it to Gateway, Gateway renders it into a `%Jido.Signal{}` and publishes.
3. Provides `BullX.Gateway.deliver/1` and `BullX.Gateway.cancel_stream/1` — full semantics in RFC 0003.
4. Provides DLQ ops API `list_dead_letters/1` / `replay_dead_letter/1` — full semantics in RFC 0003.
5. Maintains `AdapterRegistry`, mapping `{adapter, tenant}` to an adapter module, config, and retry policy.
6. **ControlPlane**: durable writes to `gateway_trigger_records` and `gateway_dedupe_seen` (both `UNLOGGED`, this RFC), and to `gateway_dispatches` / `gateway_attempts` / `gateway_dead_letters` (RFC 0003).
7. Maintains per-scope `ScopeWorker` processes for outbound serialization (RFC 0003).
8. Performs `(source, id)` inbound dedupe (ETS hot cache + `gateway_dedupe_seen` durable backing + a **partial** unique index on `gateway_trigger_records.dedupe_key WHERE published_at IS NULL`, defense in depth for in-flight records, per-adapter TTL).
9. Performs `delivery.id` outbound dedupe (RFC 0003).
10. Runs the policy pipeline hooks defined in §6.8.
11. Emits telemetry: publish failed / adapter crashed / queue length / delivery succeeded / failed / pipeline decisions.

### 2.2 What Gateway Core explicitly does not do (cross-cutting non-goals)

- Does not model business events. GitHub issues, Stripe payments, Kafka offsets, market ticks, Feishu domain payloads — all owned by adapters. Gateway transports `adapter_event` as an opaque map.
- Does not define a generic `WebhookRequest`, does not enforce a signature framework, does not touch raw body / headers / query / remote IP. The single exception is `BullXGateway.Webhook.RawBodyReader` (§6.6), a body-reader helper.
- Does not own session, turn, memory, knowledge, budget, approval, HITL, cron, subagent, agent orchestration, or "interrupt agent on new message" concurrency. Those belong to Runtime.
- Does not introduce `%Room{}` / `%Participant{}` / `%Thread{}` / `%RoomBinding{}` / `%RoutingPolicy{}`. No thread lifecycle, participant registry, presence, or typing.
- Does not model platform-specific semantics like `ModalClose` or `AssistantThreadStarted`.
- Does not maintain media long-term storage or a unified media cache; adapters handle that.
- Does not filter think-blocks or reasoning content (Runtime).
- Does not enumerate `failure_class` / retry taxonomy as a protocol contract. `error.kind` is supplied by adapters; Runtime decides retry semantics for itself.
- Does not perform cross-node routing, distributed bus, or global consistency.
- Does not perform audit-grade rejection persistence (rejections go to `:telemetry`; a future `BullXGateway.AuditSink` behaviour may add this).
- Does not attempt mid-stream durability (only the `stream_close` outcome is durable; see RFC 0003).
- Does not ship default Gating / Moderation / Security implementations; the application layer provides them.

### 2.3 Inbound-focused do / don't

**Do (this RFC):**

- Render canonical `%Jido.Signal{}` envelopes with the dual projection contract.
- Validate carrier shape, never event-domain semantics.
- Persist inbound events to `gateway_trigger_records` before adapter ack.
- Record `(source, id)` dedupe in `gateway_dedupe_seen` only after a successful Bus publish.
- Run the inbound policy pipeline (`Security → Dedupe → Gating → Moderation → store → publish`).
- Recover unpublished trigger records via `InboundReplay` (boot + periodic + on-demand).

**Don't (this RFC):**

- Don't validate `adapter_event.data` field-by-field.
- Don't whitelist `adapter_event.type` values.
- Don't write a rejection record to `gateway_trigger_records` for `Security` / `Gating` / `Moderation` denials — those rejections live in telemetry only, so the external source can retry.
- Don't bake an adapter's `ActorResolver` into the Gateway protocol; the protocol only reserves a slot (`actor.app_user_id`).
- Don't subscribe to the Bus with persistent / ack-checkpointing semantics; durability is the ControlPlane's job.

## 3. Design constraints

The eleven constraints that frame the Gateway design as a whole:

1. **Single node.** No cross-node routing, no distributed bus, no global consistency.
2. **PostgreSQL is required.** Gateway uses `BullX.Repo` (PostgreSQL) for durable intake, dedupe backing, and the DLQ. Most tables are `UNLOGGED` (truncated on unclean server crash, accepted); `gateway_dead_letters` (RFC 0003) is the only `LOGGED` table. dev / test go through the Ecto sandbox; no ETS-only backend is maintained.
3. **Process isolation.** A single channel / scope / listener failure must not propagate to the rest of Gateway.
4. **New channel = incremental extension.** Adding an adapter must not change the Gateway Core protocol or the supervision tree skeleton.
5. **Inbound uses `Jido.Signal`.** No second event envelope is invented.
6. **Outbound uses a separate `BullXGateway.Delivery` struct.** Inbound and outbound are not stuffed into one type.
7. **Bus routing is by `signal.type` pattern.** `Jido.Signal.Bus.subscribe/3` is the real semantics; there is no parallel topic-PubSub.
8. **`time` is an ISO8601 string; `specversion` must be exactly `"1.0.2"`.** See Appendix A.
9. **Gateway-produced signals prefer the external stable event id as `signal.id`.** When omitted, `Jido.Signal.new/1` generates a UUID7.
10. **No persistent / ack-checkpoint Bus subscriptions.** Plain publish / subscribe only; durability is the ControlPlane's responsibility.
11. **Startup order is the ingress gate.** There is no `IngressControl` on/off switch. The application starts `BullXGateway.AdapterSupervisor` only after `BullX.Runtime.Supervisor` is ready. Even when Runtime is late, durable ControlPlane buffers events, so nothing is lost.

## 4. Internal event protocol

### 4.1 Signal type list

Gateway Core defines exactly **three** stable carrier `signal.type` values:

```text
com.agentbull.x.inbound.received     # all inbound (chat / edits / recalls / reactions / actions / slash / triggers)
com.agentbull.x.delivery.succeeded   # outbound success (RFC 0003)
com.agentbull.x.delivery.failed      # outbound failure (RFC 0003)
```

Adding a new external source or event subtype does not add a new carrier type. Adapters express variation through `data.event_category` (the Gateway-owned canonical axis) and `data.adapter_event.type` (the adapter-owned platform-specific subtype).

This RFC owns `com.agentbull.x.inbound.received`. The two `delivery.*` types are produced by the egress path defined in RFC 0003; the carrier name and Bus subscription pattern are introduced here so the Bus contract is complete from one document.

Bus subscription example:

```elixir
# Runtime subscribes to all inbound signals
Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.inbound.**",
  dispatch: {:pid, target: runtime_dispatcher}
)

# The handler dispatches by data.event_category:
fn signal ->
  case signal.data["event_category"] do
    "message"          -> handle_chat_message(signal)
    "message_edited"   -> handle_message_edit(signal)
    "message_recalled" -> handle_message_recall(signal)
    "reaction"         -> handle_reaction(signal)
    "action"           -> handle_card_action(signal)
    "slash_command"    -> handle_slash(signal)
    "trigger"          -> handle_webhook(signal)
  end
end

# Outbound result subscription (RFC 0003 produces these)
Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.delivery.**",
  dispatch: {:pid, target: runtime_delivery_watcher}
)
```

### 4.2 Dual projection contract

**Every inbound signal's `data` is a Gateway-rendered canonical payload, not a verbatim mirror of the `BullXGateway.Inputs.*` struct the adapter submitted.**

The two projections that are always present:

| Field | Audience | Notes |
| --- | --- | --- |
| `agent_text` | LLM / Agent prompt | Natural-language summary, **required, non-empty**. For categories without natural text (`reaction`, `message_recalled`), Gateway renders a default template if the adapter did not supply one. The Agent reads this single field and understands what happened. |
| `adapter_event` | Machine routing / tool calls / audit | Structured fact, **required**. Shape: `%{"type" => "<adapter>.<event>", "version" => 1, "data" => %{...}}`. |

Other stable inbound fields (full shape in §4.6 / §4.7):

- `event_category` — Gateway-owned canonical classification (one of seven values), required.
- `duplex` — boolean, derived from `event_category` (six chat-style categories are `true`, `trigger` is `false`).
- `content` — list of canonical content blocks, defaults to `[]`. The block contract is shared with outbound and lives in §5.2.
- `actor` — `%{id, display, bot, app_user_id}`; the first three required, `app_user_id` optional.
- `refs` — list of stable anchors `[%{kind, id, url?}]`, defaults to `[]`.
- `reply_channel` — only present when `duplex = true`: `%{adapter, tenant, scope_id, thread_id?}`. Omitted (or `nil`) when `duplex = false`.
- Category-specific fields (§4.3).

`BullXGateway.Inputs.*` are internal Elixir structs the adapter passes to Gateway; they may use atom keys. When rendering the `%Jido.Signal{}`, Gateway must canonicalize:

1. Recursively normalize map keys from atom / mixed-key to string-key.
2. Project values that the protocol requires to be JSON-friendly into strings (e.g. `content.kind`, `Outcome.status`, `reaction.action :: :added | :removed` to `"added"` / `"removed"`).
3. Validate that the final `%Jido.Signal{}`'s `data` and `extensions` are JSON-neutral (no atoms, no `DateTime`, no structs, no functions).

Data flow:

```text
External raw payload
  -> Adapter-private parser / verifier (HMAC / JWT / timestamp window / ...)
  -> Adapter-owned typed event struct (e.g. GitHub.Events.IssueOpened, optional)
  -> Adapter produces projections:
       1. agent_text       (adapter-chosen logic)
       2. adapter_event    (adapter-chosen logic)
       3. content / refs / actor / category-specific fields
  -> One of BullXGateway.Inputs.* canonical structs (one of seven)
  -> BullX.Gateway.publish_inbound(input)
  -> Gateway pipeline: Security -> Dedupe -> Gating -> Moderation -> durable write -> Bus.publish
  -> Runtime / skill receives Signal with dual projection
```

### 4.3 Event categories (seven canonical structs)

Gateway defines seven canonical category structs under `BullXGateway.Inputs.*`. Adapters must map every external event to one of them. The classification follows generic IM semantics, not any single platform's API.

| Category | Gateway struct | `data.event_category` | duplex | Typical sources |
| --- | --- | --- | --- | --- |
| Chat new message (text + media) | `BullXGateway.Inputs.Message` | `"message"` | true | Feishu / Slack / Discord message posted |
| Message edited | `BullXGateway.Inputs.MessageEdited` | `"message_edited"` | true | Feishu `im.message.updated_v1`, Slack `message_changed`, Discord `MESSAGE_UPDATE` |
| Message recalled | `BullXGateway.Inputs.MessageRecalled` | `"message_recalled"` | true | Feishu `im.message.recalled_v1`, etc. |
| Emoji reaction add / remove | `BullXGateway.Inputs.Reaction` | `"reaction"` | true | Feishu / Slack / Discord reaction |
| Interactive component (button / form / modal submit) | `BullXGateway.Inputs.Action` | `"action"` | true | Feishu card button, Slack `view_submission`, ... |
| Slash command | `BullXGateway.Inputs.SlashCommand` | `"slash_command"` | true | `/help`, `/status`, ... |
| Non-chat event (webhook / polling / feed / tick) | `BullXGateway.Inputs.Trigger` | `"trigger"` | false | GitHub webhook, Stripe webhook, market tick |

**Deliberately not separate categories:**

- **Modal submit** is not a separate category — semantically it is a form submit, a special `Action` (payload contains form values). Adapters use `adapter_event.type = "slack.view_submission"` / `"feishu.card.form_submit"` to distinguish platform subtypes; the protocol treats it as `Action`.
- **Modal close / dismiss** is not modelled — Slack-specific, weak semantics, Runtime almost never needs to respond. An adapter that insists may carry it as `Action` (`adapter_event.type = "slack.view_closed"`); not recommended.
- **Assistant thread started / context changed** (jido_chat has it) is not modelled — Slack Assistant Panel-specific integration; BullX has no use today; add when needed.
- **The message lifecycle triplet** (`Message` / `MessageEdited` / `MessageRecalled`) is intentional — most IM platforms support these natively, and editing one's own message is a daily occurrence.

### 4.4 Identity and dedupe

`(source, id)` is the primary idempotency contract.

- `source` is a stable adapter instance URI:
  - `bullx://gateway/feishu/default`
  - `bullx://gateway/github/default`
- `id` prefers the external stable event id:
  - Feishu event id;
  - GitHub delivery id (`X-GitHub-Delivery`);
  - When one external delivery is split into multiple internal signals, the adapter derives stable child ids: `<delivery_id>#0`, `<delivery_id>#1`;
  - For reactions / edits / recalls without a native id, adapters synthesize a stable id: `"#{event_type}:#{target_message_id}:#{actor_id}:#{action_time}"`.

Adapters may perform stateful normalization on raw events (re-aggregate split-and-reassembled chunks, merge album batches, drop bot self-echo). Gateway Core only requires that the final per-signal `(source, id)` pair satisfy the idempotency contract.

The `Deduper`'s ETS hot cache is a performance optimization. The authoritative source is `gateway_dedupe_seen` (UNLOGGED with a unique index). `gateway_trigger_records` adds a **partial** unique index on `dedupe_key WHERE published_at IS NULL` as defense in depth for the "stored but not yet published" window. See §7.7.

### 4.5 `Jido.Signal` envelope

```elixir
%Jido.Signal{
  specversion: "1.0.2",
  id: "evt_...",                      # external stable event id (dedupe primary key source)
  source: "bullx://gateway/feishu/default",
  type: "com.agentbull.x.inbound.received"
       | "com.agentbull.x.delivery.succeeded"
       | "com.agentbull.x.delivery.failed",
  subject: "feishu:chat_abc",         # human-readable / log display only
  time: "2026-04-21T10:00:00Z",
  datacontenttype: "application/json",
  data: %{...},                       # see §4.6
  extensions: %{
    "bullx_channel_adapter" => "feishu",          # required
    "bullx_channel_tenant"  => "default",         # required
    "bullx_caused_by"       => "<source inbound id>"  # optional (delivery.* often present, inbound rarely)
    # Optional policy pipeline extension keys (§6.8):
    # "bullx_security"             => %{...}
    # "bullx_flags"                => [%{stage, module, reason, description}, ...]
    # "bullx_moderation_modified"  => true
  }
}
```

Constraints:

- `type` / `source` / `id` / `subject` / `time` are strings.
- `data` and `extensions` are JSON-neutral (string keys, no atoms / `DateTime` / structs / functions).
- `subject` is for logs / UI / debugging only. **Machine logic must not parse `subject`.** Routing reads `extensions` or `data`.
- `extensions` carries only **envelope-level provenance**: the three fixed keys plus optional policy extension keys (§6.8). Business payload (`scope_id`, `thread_id`, `actor`, ...) is read from `data`, not duplicated into `extensions`.

### 4.6 Inbound payload examples (`com.agentbull.x.inbound.received`)

All inbound events share this single carrier. `data.event_category` determines the category-specific shape; `data.duplex` determines whether reverse writes are possible.

**Example 1: Feishu group chat message (`event_category = "message"`)**

```elixir
%Jido.Signal{
  id: "om_abc123",
  source: "bullx://gateway/feishu/default",
  type: "com.agentbull.x.inbound.received",
  subject: "feishu:oc_xxx",
  time: "2026-04-21T10:00:00Z",
  datacontenttype: "application/json",
  data: %{
    "event_category" => "message",
    "duplex" => true,

    # Flat scope contract (shared across all categories;
    # the same fields appear inside reply_channel for duplex categories):
    "scope_id" => "oc_xxx",
    "thread_id" => nil,

    "agent_text" => "Boris: please summarize today's GitHub issues",

    "content" => [
      %{"kind" => "text", "body" => %{"text" => "please summarize today's GitHub issues"}}
    ],

    "adapter_event" => %{
      "type" => "feishu.message.posted",
      "version" => 1,
      "data" => %{
        "message_id" => "om_abc123",
        "chat_id" => "oc_xxx",
        "chat_type" => "group",
        "message_type" => "text",
        "mentions" => [],
        "reply_to_message_id" => nil
      }
    },

    "actor" => %{
      "id" => "feishu:user_xxx",
      "display" => "Boris",
      "bot" => false,
      "app_user_id" => "uuid-bullx-boris"   # optional, see §4.8 identity bridging
    },

    "refs" => [
      %{"kind" => "feishu.message", "id" => "om_abc123"},
      %{"kind" => "feishu.chat",    "id" => "oc_xxx"}
    ],

    "reply_channel" => %{
      "adapter" => "feishu",
      "tenant"  => "default",
      "scope_id" => "oc_xxx",
      "thread_id" => nil
    }
    # Message has no extra category-specific required fields.
  },
  extensions: %{
    "bullx_channel_adapter" => "feishu",
    "bullx_channel_tenant"  => "default"
  }
}
```

Notes:

- `agent_text` is the Agent prompt's **preferred** input, not a fallback. The adapter assembles it (and may include a parent-message snippet).
- `content` is the canonical content slot. If a message has images / files / audio, the adapter appends the corresponding blocks in original order (`image` / `file` / `audio`) instead of hiding them inside `adapter_event.data`.
- `adapter_event.type` is adapter-defined; under one `event_category = "message"` you might see `"feishu.message.text"`, `"feishu.message.file"`, `"slack.message.shared"`, ... Gateway Core does not enumerate or validate these.
- `adapter_event.version` is for adapter-internal schema evolution; Gateway only verifies it exists and is an integer.
- `refs` gives Runtime / tools stable anchors so they need not parse text.
- `reply_channel` lets Runtime build a Delivery; required when `duplex = true`.

**Example 2: GitHub issue opened webhook (`event_category = "trigger"`)**

```elixir
%Jido.Signal{
  id: "8f7fdc1d-...",                              # GitHub delivery id
  source: "bullx://gateway/github/default",
  type: "com.agentbull.x.inbound.received",
  subject: "github:acme/api",
  time: "2026-04-21T10:00:00Z",
  datacontenttype: "application/json",
  data: %{
    "event_category" => "trigger",
    "duplex" => false,

    # trigger has no reply_channel, but scope_id / thread_id are still required:
    "scope_id" => "acme/api",
    "thread_id" => nil,

    "agent_text" =>
      "GitHub repo acme/api has a new issue #101: Database latency spike\n" <>
      "URL: https://github.com/acme/api/issues/101\n" <>
      "by octocat",

    "content" => [],

    "adapter_event" => %{
      "type" => "github.issue.opened",
      "version" => 1,
      "data" => %{
        "repository" => "acme/api",
        "issue_number" => 101,
        "issue_title" => "Database latency spike",
        "issue_url" => "https://github.com/acme/api/issues/101",
        "sender_login" => "octocat"
      }
    },

    "actor" => %{
      "id" => "github:octocat",
      "display" => "octocat",
      "bot" => false,
      "app_user_id" => nil                         # GitHub webhook senders rarely have a BullX user
    },

    "refs" => [
      %{"kind" => "github.repo",  "id" => "acme/api",
        "url" => "https://github.com/acme/api"},
      %{"kind" => "github.issue", "id" => "acme/api#101",
        "url" => "https://github.com/acme/api/issues/101"}
    ]
    # duplex = false: reply_channel omitted.
  },
  extensions: %{
    "bullx_channel_adapter" => "github",
    "bullx_channel_tenant"  => "default"
  }
}
```

Notes:

- Gateway does not know what a GitHub issue is; it carries `adapter_event` as an opaque map.
- `content = []` indicates this trigger has no canonical message-body projection. If a class of trigger does carry a body (e.g. webhook comment body, polling feed attachments), the adapter populates `content` rather than inventing a private field.
- No `reply_channel`: to respond (e.g. comment on the issue), Runtime must call the GitHub tool / action that hits the GitHub API directly. Gateway `deliver/1` does not apply.
- `refs` is the stable anchor list for tool calls; skills do not regex-parse `agent_text` to extract `acme/api#101`.
- `scope_id = "acme/api"` is an adapter-defined aggregation key (repo level). A Shopify adapter might use `"shop_id:order"`; a Kafka adapter might use `"topic:partition"`. Gateway does not interpret `scope_id`'s internal structure.
- When the external source has no natural actor (market tick, polling feed, system alert), the adapter must supply a synthetic actor: `%{"id" => "system:market-feed", "display" => "Market Feed", "bot" => true, "app_user_id" => nil}`.

**Example 3: emoji reaction (`event_category = "reaction"`)**

```elixir
data: %{
  "event_category" => "reaction",
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "agent_text" => "Boris reacted thumbs-up to a message",   # Gateway default template; adapter may override
  "content" => [],
  "adapter_event" => %{
    "type" => "feishu.reaction.created",
    "version" => 1,
    "data" => %{"reaction_type" => "THUMBSUP"}
  },
  "actor" => %{"id" => "feishu:user_xxx", "display" => "Boris", "bot" => false, "app_user_id" => "..."},
  "refs"  => [%{"kind" => "feishu.message", "id" => "om_target"}],

  # category-specific
  "target_external_message_id" => "om_target",
  "emoji"  => "THUMBSUP",
  "action" => "added",                                       # "added" | "removed"

  "reply_channel" => %{"adapter" => "feishu", "tenant" => "default", "scope_id" => "oc_xxx", "thread_id" => nil}
}
```

**Example 4: message edited (`event_category = "message_edited"`)**

```elixir
data: %{
  "event_category" => "message_edited",
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "agent_text" => "Boris edited: please summarize **all** of today's GitHub issues",   # new text or template
  "content" => [
    %{"kind" => "text", "body" => %{"text" => "please summarize **all** of today's GitHub issues"}}
  ],
  "adapter_event" => %{
    "type" => "feishu.message.edited",
    "version" => 1,
    "data" => %{"message_id" => "om_abc123", "edit_count" => 2}
  },
  "actor" => %{...},
  "refs"  => [%{"kind" => "feishu.message", "id" => "om_abc123"}],

  # category-specific
  "target_external_message_id" => "om_abc123",
  "edited_at" => "2026-04-21T10:02:00Z",

  "reply_channel" => %{...}
}
```

**Example 5: message recalled (`event_category = "message_recalled"`)**

```elixir
data: %{
  "event_category" => "message_recalled",
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "agent_text" => "Boris recalled a message",
  "content" => [],
  "adapter_event" => %{
    "type" => "feishu.message.recalled",
    "version" => 1,
    "data" => %{"message_id" => "om_abc123", "recall_time" => "..."}
  },
  "actor" => %{...},
  "refs"  => [%{"kind" => "feishu.message", "id" => "om_abc123"}],

  # category-specific
  "target_external_message_id" => "om_abc123",
  "recalled_by_actor" => %{...},                          # may equal top-level actor
  "recalled_at" => "2026-04-21T10:05:00Z",

  "reply_channel" => %{...}
}
```

**Example 6: card button click (`event_category = "action"`; same shape applies to modal submit)**

```elixir
data: %{
  "event_category" => "action",
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "agent_text" => "Boris clicked: Approve",
  "content" => [],
  "adapter_event" => %{
    "type" => "feishu.card.action_clicked",             # or "slack.view_submission" for modal submit
    "version" => 1,
    "data" => %{"tenant_key" => "..."}                  # platform-specific kept here
  },
  "actor" => %{...},
  "refs"  => [%{"kind" => "feishu.message", "id" => "om_card"}],

  # category-specific
  "target_external_message_id" => "om_card",
  "action_id" => "approve",
  "values" => %{                                         # opaque map; button value / form values / modal submit state
    "clarify_id"   => "clr_1",
    "tool_call_id" => "tc_1",
    "choice"       => "approve"
  },

  "reply_channel" => %{...}
}
```

**Example 7: slash command (`event_category = "slash_command"`)**

```elixir
data: %{
  "event_category" => "slash_command",
  "duplex" => true,
  "scope_id" => "oc_xxx",
  "thread_id" => nil,
  "agent_text" => "/status",
  "content" => [],
  "adapter_event" => %{"type" => "feishu.command.issued", "version" => 1, "data" => %{}},
  "actor" => %{...},
  "refs"  => [...],

  # category-specific
  "command_name" => "status",
  "args" => "",

  "reply_channel" => %{...}
}
```

### 4.7 Adapter event granularity guidelines

**The adapter event model is not the external platform's full schema. It is the minimal stable projection that Agent / Runtime / tools need.**

- Do not stuff an entire GitHub webhook payload into `adapter_event.data` — pick the fields Runtime will actually use (repo, issue number, title, URL, sender).
- Do not relay all 100+ Stripe fields — pick the ones the business cares about (amount, currency, customer_id, payment_intent_id).
- One external event may map to multiple `adapter_event.type` values (e.g. GitHub `pull_request` events split by `action` into `github.pull_request.opened` / `github.pull_request.merged`).
- Conversely, one `adapter_event.type` may aggregate multiple external events (e.g. the market adapter coalesces 1 second of ticks into one `market.tick.received`).
- `adapter_event.version` is for adapter-owned schema evolution. v1 -> v2 should preserve backward compatibility or break explicitly; the adapter's RFC owns that policy.
- **`event_category` is Gateway's; `adapter_event.type` is the adapter's.** Two layers of typed projection, with clean separation. Runtime can dispatch on both (coarse by `event_category`, fine by `adapter_event.type`).

A sizing rule of thumb (inspired by jido_integration's devops proof): a handler that needs `repository` / `issue_number` / `issue_title` from `adapter_event` already has enough to do incident routing ("page oncall"); it does not need the entire GitHub payload.

### 4.8 `subject`, `extensions`, and user identity bridging

**`subject`** is a human-readable aggregation key string:

```text
<adapter>:<scope>[:<thread>]
```

Examples: `feishu:oc_xxx`, `feishu:oc_xxx:topic_12`, `github:acme/api`.

**Machine logic must not parse `subject`.** Routing, cache keys, tool arguments must read `data` or `extensions`.

**`extensions`** carries only envelope-level provenance — the three fixed keys:

```elixir
%{
  "bullx_channel_adapter" => "feishu" | "github" | "slack" | ...,  # required
  "bullx_channel_tenant"  => "default",                             # required
  "bullx_caused_by"       => "<source inbound signal id>"           # optional (delivery.* often)
}
```

Optional policy pipeline extension keys (§6.8):

- `"bullx_security"` — metadata returned by `Security.verify_sender` (when the adapter chooses to populate it);
- `"bullx_flags"` — `[%{"stage", "module", "reason", "description"}, ...]`, accumulated by `Moderation`;
- `"bullx_moderation_modified"` — `true` when at least one moderator returned `:modify`.

**`scope_id` and `thread_id` are not put in `extensions`** (they live in `data`). Routing uses `signal.type`; `extensions` is provenance / audit only.

**There is no `bullx_scope_kind`** (`"dm" | "group" | "channel"`). Forcing webhook sources to pretend to be chat scopes only creates semantic pollution. `dm` / `group` / `channel` / `repo` / `feed` are adapter-internal semantics (and may live in `adapter_event.data.chat_type` for example); Gateway Core need not understand them.

Bot-self-echo filtering and bot-message identification are adapter responsibilities; the adapter drops them internally. No dedicated extension flag exists.

#### User identity bridging (load-bearing)

The `actor` field carries two kinds of identity:

```elixir
actor = %{
  # Required: stable platform-side identity
  # (Gateway carrier layer assumes nothing about the BullX user system)
  "id"      => "feishu:user_open_id_xxx" | "slack:U01ABC" | "github:octocat" | ...,
  "display" => "Boris",
  "bot"     => false,

  # Optional: when the adapter can resolve the platform identity to a BullX user_id, fill it.
  # The BullX user system itself is defined by a future RFC (`BullX.Users` does not yet exist);
  # the Gateway protocol layer reserves this slot only — it does not mandate a resolver.
  "app_user_id" => nil | "uuid-xxx"
}
```

**Resolver strategy** (adapter-implemented; Gateway does not enforce):

- A typical approach: adapter takes `feishu_user_id` -> calls Feishu contact API for the mobile -> looks up BullX `users` by phone -> obtains internal `user_id`. Or the adapter performs platform OAuth binding directly.
- Gateway's only requirement: **`actor.id` is required and stably identifies the sender across events**; `app_user_id` may be `nil` (no resolver, not onboarded, no matching BullX user).
- Runtime / skill consumption: prefer reading `actor.app_user_id` when present for business-level identity routing; fall back to `actor.id` for platform-level routing.
- Gateway **does not introduce a dedicated `ActorResolver` behaviour** — the resolver is an adapter-internal implementation detail (similar to signature verification, §6.6) and the adapter's responsibility. The Gateway only defines the contract slot.

### 4.9 Typed signal modules

The Gateway defines exactly **three** typed signal modules, each with `new/1` and `new!/1`:

- `BullXGateway.Signals.InboundReceived`
- `BullXGateway.Signals.DeliverySucceeded` (RFC 0003)
- `BullXGateway.Signals.DeliveryFailed` (RFC 0003)

`InboundReceived.new/1` contract:

```elixir
@type input ::
        BullXGateway.Inputs.Message.t()
        | BullXGateway.Inputs.MessageEdited.t()
        | BullXGateway.Inputs.MessageRecalled.t()
        | BullXGateway.Inputs.Reaction.t()
        | BullXGateway.Inputs.Action.t()
        | BullXGateway.Inputs.SlashCommand.t()
        | BullXGateway.Inputs.Trigger.t()

@spec new(input()) :: {:ok, Jido.Signal.t()} | {:error, term()}
```

#### Inbound carrier validation: carrier only

`BullXGateway.Inputs.*` may arrive at `InboundReceived.new/1` as internal atom-key structs. The first step canonicalizes; the second step validates the final signal payload.

**Validation steps** (executed in order):

1. **Top level:** `type` is exactly `"com.agentbull.x.inbound.received"`; `source`, `id`, `time` are non-empty; `specversion = "1.0.2"`.
2. **JSON projection:** `data` and `extensions` are string-key JSON-neutral maps.
3. **Extensions provenance:** `bullx_channel_adapter` and `bullx_channel_tenant` exist and are non-empty; optional keys are validated when present.
4. **Event category:** `data.event_category` is one of the seven allowed values; `data.duplex` is a boolean and consistent with `event_category` (six chat categories `true`, `trigger` `false`).
5. **Dual projection:**
   - `data.agent_text` is a non-empty string (Gateway's default template renders this for `reaction` / `message_recalled` if the adapter did not provide it).
   - `data.content` is a list of `%{"kind" => kind_string, "body" => map}`; `[]` is allowed but the field is not omitted.
   - `data.content[].kind` is one of the six stable kinds: `"text" | "image" | "audio" | "video" | "file" | "card"`.
   - For non-`"text"` kinds, `content.body["fallback_text"]` is a required non-empty string (the only hard contract in §5.2).
   - `data.adapter_event.type` is a non-empty string (the value is not checked against any whitelist).
   - `data.adapter_event.version` is an integer.
   - `data.adapter_event.data` is a map (may be `%{}`, but must be a map).
6. **Stable fields:**
   - **`data.scope_id`** is required and a non-empty string. All categories share it; the inbound carrier surfaces it at the top of `data` (not only inside `reply_channel`).
   - **`data.thread_id`** is a required key whose value may be `nil` or a non-empty string. All categories must include the key; the value is adapter-decided.
   - `data.actor` contains at least `%{"id" => non_empty_string, "display" => string, "bot" => bool}`; `"app_user_id"` may be `nil` or a non-empty string.
   - `data.refs` is a list of `%{"kind" => _, "id" => _, "url" => _ | nil}`; defaults to `[]`.
   - When `duplex = true`, `data.reply_channel` is required: `%{"adapter" => _, "tenant" => _, "scope_id" => _, "thread_id" => _ | nil}`. Its `scope_id` / `thread_id` should match the top-level `data.scope_id` / `data.thread_id` (redundant but lets Runtime build a Delivery without crossing fields).
   - When `duplex = false`, `data.reply_channel` is omitted or `nil`; the top-level `data.scope_id` / `data.thread_id` are still required.
7. **Category-specific:** see §4.3 struct fields. For example, `Reaction` requires `target_external_message_id`, `emoji`, `action ∈ {"added", "removed"}`; `MessageEdited` requires `target_external_message_id`; `Action` requires `target_external_message_id` and `action_id`; etc.

**Not validated:**

- The specific value of `adapter_event.type` (no allowed-value whitelist).
- Field-level shape of `adapter_event.data` (Gateway does not know what a GitHub issue contains).
- `content.body` beyond the §5.2 minimum carrier contract (e.g. card payload schema).
- `refs[].kind` whitelist.
- The textual format of `agent_text` (only non-emptiness is checked).
- The format of `actor.app_user_id` beyond "nil or non-empty string".

This is exactly what **"Gateway validates the carrier, not the event"** means in practice.

#### Usage constraint

**Adapters and Runtime must not bypass the typed signal module by constructing `%Jido.Signal{}` and calling `Bus.publish/2` directly for inbound.** The inbound path must go through `BullX.Gateway.publish_inbound/1`, which internally calls `InboundReceived.new/1`. If rendering or validation fails, `publish_inbound/1` returns `{:error, reason}` and the signal does not enter the Bus.

`new!/1` is the fast path for already-clean inputs (raises on failure).

The two outbound result signal modules (`DeliverySucceeded`, `DeliveryFailed`) are defined in RFC 0003.

## 5. Content body shape (shared)

This RFC owns the authoritative definition of `BullXGateway.Delivery.Content`'s body shape because the same shape is used by inbound `data["content"][]` blocks. RFC 0003 references this section without redefining it.

```elixir
defmodule BullXGateway.Delivery.Content do
  @type kind :: :text | :image | :audio | :video | :file | :card
  @type t :: %__MODULE__{kind: kind(), body: map()}
end
```

Once a `Content.kind` enters the Gateway protocol it must satisfy a minimum `body` contract. The contract applies both to outbound `BullXGateway.Delivery.Content` and to inbound `data["content"][]` canonical blocks (inbound blocks project `kind` to a string).

**Minimum body shape** (every non-`:text` kind must include `fallback_text` as a non-empty string — this is the **only hard contract** Gateway enforces, it underwrites every degradation path):

- `:text` — `%{"text" => String.t()}`.
- `:image` — `%{"url" => String.t(), "fallback_text" => String.t(), "media_type" => String.t() | nil, "alt_text" => String.t() | nil, "width" => non_neg_integer() | nil, "height" => non_neg_integer() | nil, "size_bytes" => non_neg_integer() | nil}`.
- `:audio` — `%{"url" => String.t(), "fallback_text" => String.t(), "media_type" => String.t() | nil, "duration" => non_neg_integer() | nil, "transcript" => String.t() | nil, "size_bytes" => non_neg_integer() | nil}`.
- `:video` — `%{"url" => String.t(), "fallback_text" => String.t(), "media_type" => String.t() | nil, "duration" => non_neg_integer() | nil, "width" => non_neg_integer() | nil, "height" => non_neg_integer() | nil, "thumbnail_url" => String.t() | nil, "size_bytes" => non_neg_integer() | nil}`.
- `:file` — `%{"url" => String.t(), "fallback_text" => String.t(), "filename" => String.t() | nil, "media_type" => String.t() | nil, "size_bytes" => non_neg_integer() | nil}`.
- `:card` — `%{"format" => String.t(), "payload" => map(), "fallback_text" => String.t()}`.

The shape is "**`kind` enum + `body` is a map + non-text kinds have `fallback_text`**" plus an agreed-on shape for the rest (consumers that cannot read a field fall back to `fallback_text`). Additional fields are allowed.

**Single `url` URI field.** The previous design separated `url` (HTTP) from `data` (data URI). This RFC merges them into a single `url`: the string itself is a URI, supporting any scheme — `https://cdn.example.com/xxx.png` (external) or `data:image/png;base64,iVBORw0KGgo...` (inline data URI). Both are URIs, splitting them serves no purpose. Consumers dispatch by URI scheme. The field is **required, non-empty**. The `path` option is removed: Gateway does not abstract local-file access; an adapter holding local bytes must upload to a URL or encode as a data URI before populating `url`.

**No max-size cap.** Sizing is the adapter author's responsibility. Large files must be uploaded to an external store and referenced by an HTTP(S) URL; multi-megabyte data URIs in a Signal are not allowed. The reasoning: a cap inside Gateway would either be too low for some legitimate adapter (forcing a workaround) or too high to provide real protection. Adapters know their platform's payload limits and own the decision.

This is only the minimum delivery contract; it is not a unified media cache. Adapters remain responsible for magic-byte detection, upload / download, platform limits, chunking, native fallback, and platform-private card schemas.

## 6. Channel and adapter

### 6.1 Channel identity and registration

**A channel is identified by `{adapter_atom, tenant_string}`.**

Examples: `{:feishu, "default"}`, `{:feishu, "tenant_a"}`, `{:github, "default"}`.

Adapter modules do not declare channels statically via `channel/0`; the tenant is per-instance configuration, not a module-level static attribute:

```elixir
BullXGateway.AdapterRegistry.register(
  {:feishu, "default"},
  BullXGateway.Adapters.Feishu,
  config
)
```

`config` shape (Gateway-shared metadata + adapter-specific fields):

```elixir
%{
  # shared metadata (read by Gateway)
  dedupe_ttl_ms: 5 * 60 * 1000,              # per-adapter dedupe TTL
  retry_policy: %{                            # outbound retry policy (RFC 0003)
    max_attempts: 5,
    base_backoff_ms: 1000,
    max_backoff_ms: 30_000
  },

  # adapter-specific (read by the adapter)
  app_id: "cli_xxx",
  app_secret: "xxx",                          # credential management is in BullX.Config (RFC 0001)
  ...
}
```

### 6.2 The `BullXGateway.Adapter` behaviour

Adapters are registered and started under the supervision tree owned by this RFC, so the **full** behaviour definition lives here. Egress call-contract details (when ScopeWorker calls `deliver/2` / `stream/3`, retry semantics, etc.) are spelled out in RFC 0003.

```elixir
defmodule BullXGateway.Adapter do
  @type context :: %{
          required(:channel) => BullX.Delivery.channel(),
          required(:config) => map(),
          required(:telemetry) => map(),
          optional(atom()) => term()
        }

  # op capabilities — correspond to BullX.Delivery.op(); used by Gateway deliver/1 pre-check
  @type op_capability :: :send | :edit | :stream
  # metadata capabilities — adapter self-description for UI / Runtime reference; not used in pre-check
  @type metadata_capability :: :reactions | :cards | :threads | atom()
  @type capability :: op_capability() | metadata_capability()

  @callback adapter_id() :: atom()

  @callback child_specs(channel :: BullX.Delivery.channel(), config :: map()) ::
              [Supervisor.child_spec()]

  @callback deliver(BullX.Delivery.t(), context()) ::
              {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}

  @callback stream(BullX.Delivery.t(), Enumerable.t(), context()) ::
              {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}

  # capabilities/0 is required: Gateway deliver/1 pre-check depends on it
  @callback capabilities() :: [capability()]

  @optional_callbacks [
    child_specs: 2,
    deliver: 2,
    stream: 3
  ]
end
```

Callback contract:

- `adapter_id/0` **required**: module's static identity (atom).
- `child_specs/2` **optional**: the adapter starts its own listener / WebSocket / polling / webhook server / signature verifier / rate limiter / token manager. Gateway hangs them under `AdapterSupervisor`.
- `context` contains at least `%{channel, config, telemetry}`; additional fields are allowed (e.g. an anchor pid for the adapter subtree, so ScopeWorker can `Process.monitor` it).
- `deliver/2` **optional**: handles `:send` and `:edit` ops. The adapter must declare the matching op in `capabilities/0`.
- `stream/3` **optional**: handles `:stream`, consuming an `Enumerable.t()`. The adapter must declare `:stream` in `capabilities/0`.
- `capabilities/0` **required**: part of the adapter contract. Gateway `deliver/1` pre-check (RFC 0003) depends on it. Pure inbound adapters (e.g. GitHub webhook) return `[]`.

**Two capability semantics, kept separate:**

1. **Op capabilities** (`:send | :edit | :stream`) correspond one-to-one with `BullX.Delivery.op()`. Gateway `deliver/1` pre-check looks at exactly these three: when the adapter has not declared the requested op, the pre-check publishes `delivery.failed{error.kind = "unsupported"}` and writes a DLQ entry (RFC 0003).
2. **Metadata capabilities** (`:reactions | :cards | :threads | ...`) are adapter self-descriptions intended for UI / Runtime / skill **reference**. **Gateway does not use them in pre-check.** For example, when Runtime sends `Delivery{op: :send, content: %{kind: :card, ...}}` to an adapter that declared only `[:send]` (and not `:cards`), Gateway still routes the delivery to `ScopeWorker` and `deliver/2`. The adapter degrades by rendering `content.body["fallback_text"]` as plain text (§6.7). **A `:send` is rejected only when `:send` itself is missing from capabilities, not when `:cards` is missing.**

Examples:

```elixir
def capabilities, do: [:send, :edit, :stream, :reactions, :cards]

def deliver(%Delivery{op: :send} = d, ctx), do: ...
def deliver(%Delivery{op: :edit} = d, ctx), do: ...

def stream(%Delivery{op: :stream} = d, enumerable, ctx), do: ...
```

Adapter that doesn't support a particular op (e.g. Discord-only adapter without `:stream`):

```elixir
def capabilities, do: [:send, :edit]            # :stream omitted
def deliver(%Delivery{op: :send} = d, ctx), do: ...
def deliver(%Delivery{op: :edit} = d, ctx), do: ...
# stream/3 not implemented; Gateway pre-check rejects op: :stream deliveries
```

Pure inbound adapter:

```elixir
def capabilities, do: []                        # no outbound capability
# deliver/2 / stream/3 not implemented; any Delivery fails pre-check
```

A missing callback combined with a missing capability declaration means **the adapter does not support the corresponding op**. Gateway pre-check uses `capabilities/0` and never relies on `function_exported?` to decide.

### 6.3 `BullXGateway.Inputs.*` — the seven canonical input structs

An adapter listener constructs one of seven canonical structs and hands it to Gateway; Gateway renders the `%Jido.Signal{}` and publishes.

**Shared fields (every category):**

```elixir
%{
  id: String.t(),                       # external stable event id; becomes signal.id
  source: String.t(),                   # adapter instance URI
  subject: String.t() | nil,            # optional; Gateway derives "<adapter>:<scope>[:<thread>]" if omitted
  time: DateTime.t() | nil,             # optional; Gateway writes utc_now if omitted
  channel: BullX.Delivery.channel(),    # {adapter, tenant}
  scope_id: String.t(),
  thread_id: String.t() | nil,
  actor: %{
    id: String.t(),                     # required, platform identity
    display: String.t(),
    bot: boolean(),
    app_user_id: String.t() | nil       # optional, BullX user system uuid
  },
  refs: [%{kind: String.t(), id: String.t(), url: String.t() | nil}],
  adapter_event: %{
    type: String.t(),
    version: non_neg_integer(),
    data: map()
  },
  reply_channel: %{                     # only for duplex = true categories
    adapter: atom(),
    tenant: String.t(),
    scope_id: String.t(),
    thread_id: String.t() | nil
  } | nil
}
```

**Category-specific fields:**

- `BullXGateway.Inputs.Message`: `agent_text :: String.t()`, `content :: [content_block]`, `reply_to_external_id :: String.t() | nil`, `mentions :: [%{actor_id, offset_range}] | nil`.
- `BullXGateway.Inputs.MessageEdited`: `target_external_message_id :: String.t()`, `agent_text :: String.t()` (new text), `content :: [content_block]` (new blocks), `edited_at :: DateTime.t() | nil`.
- `BullXGateway.Inputs.MessageRecalled`: `target_external_message_id :: String.t()`, `recalled_by_actor :: actor() | nil` (may differ from top-level actor), `recalled_at :: DateTime.t() | nil`. `agent_text` may be supplied by the adapter or rendered by Gateway as `"<actor.display> recalled a message"`.
- `BullXGateway.Inputs.Reaction`: `target_external_message_id :: String.t()`, `emoji :: String.t()`, `action :: :added | :removed`. `agent_text` is template-defaulted by Gateway when omitted.
- `BullXGateway.Inputs.Action`: `target_external_message_id :: String.t()`, `action_id :: String.t()`, `values :: map()` (opaque — button value, form values, modal submit payload, ...).
- `BullXGateway.Inputs.SlashCommand`: `command_name :: String.t()`, `args :: String.t()`, `reply_to_external_id :: String.t() | nil`.
- `BullXGateway.Inputs.Trigger`: `agent_text :: String.t()`, `content :: [content_block]` (typically `[]`). Note that `reply_channel` does not exist (`duplex = false`).

Usage:

```elixir
input = %BullXGateway.Inputs.Trigger{
  id: github_delivery_id,
  source: "bullx://gateway/github/default",
  agent_text: GitHub.Events.IssueOpened.to_agent_text(event),
  content: [],
  adapter_event: %{
    type: "github.issue.opened",
    version: 1,
    data: %{repository: event.repository, issue_number: event.issue_number}
  },
  actor: %{
    id: "github:#{event.sender_login}",
    display: event.sender_login,
    bot: false,
    app_user_id: nil
  },
  refs: GitHub.Events.IssueOpened.to_refs(event),
  channel: {:github, "default"},
  scope_id: event.repository,
  thread_id: nil
}

case BullX.Gateway.publish_inbound(input) do
  {:ok, :published} -> ack_external_source()
  {:ok, :duplicate} -> ack_external_source()
  {:error, reason}  -> retry_via_external_source(reason)
end
```

### 6.4 Adapter event model — adapter-internal struct freedom

The Gateway protocol layer is the seven canonical category structs (§6.3); whether an adapter additionally defines a per-platform-event struct is purely an adapter engineering decision. Gateway **does not care, does not assume, does not recommend, does not forbid**.

For example, the Feishu adapter might organize internally as:

```text
BullXGateway.Adapters.Feishu.Events.MessagePosted
BullXGateway.Adapters.Feishu.Events.CardActionClicked
BullXGateway.Adapters.Feishu.Events.ReactionCreated
BullXGateway.Adapters.Feishu.Events.MessageEdited
BullXGateway.Adapters.Feishu.Events.MessageRecalled
...
```

Each adapter-internal struct typically exposes:

- `from_raw/1 :: raw_payload -> {:ok, t()} | {:error, reason}`;
- `to_canonical/1 :: t() -> BullXGateway.Inputs.*` — maps the platform event into one of Gateway's seven canonical structs;
- Or the adapter may forgo internal structs entirely and use helper functions — equally valid.

**The Gateway contract only cares which `BullXGateway.Inputs.*` canonical struct is finally submitted.** Adapter-internal code organization does not enter the Gateway contract.

**Guiding principles:**

- The canonical mapping carries only the fields Runtime / tools will use; do not relay 100+ platform fields.
- `agent_text` is a natural-language summary for the LLM. When a category has no native text (reaction / recall), Gateway can default-render.
- `adapter_event.data` is a structured projection for machine routing / tool calls; values stay JSON-friendly, keys may be atoms inside the adapter and Gateway canonicalizes at the boundary.
- `refs` exposes stable anchors so Runtime / skills do not parse `agent_text`.
- `actor.app_user_id` is filled when the adapter has a resolver (see §4.8); otherwise `nil`.

### 6.5 `publish_inbound/1` API and pipeline

```elixir
@spec BullX.Gateway.publish_inbound(
        BullXGateway.Inputs.Message.t()
        | BullXGateway.Inputs.MessageEdited.t()
        | BullXGateway.Inputs.MessageRecalled.t()
        | BullXGateway.Inputs.Reaction.t()
        | BullXGateway.Inputs.Action.t()
        | BullXGateway.Inputs.SlashCommand.t()
        | BullXGateway.Inputs.Trigger.t(),
        keyword()
      ) ::
        {:ok, :published}
        | {:ok, :duplicate}
        | {:error, {:invalid_input, term()}}
        | {:error, {:security_denied, :verify, atom(), String.t()}}
        | {:error, {:policy_denied, :gating | :moderation, atom(), String.t()}}
        | {:error, {:moderation_invalid_return, module(), term()}}
        | {:error, {:bus_publish_failed, term()}}
        | {:error, {:store_unavailable, term()}}
```

**Call flow** (the Security / Gating / Moderation hooks are defined in §6.8):

```text
External transport event
  -> adapter-private parser / verifier (HMAC / JWT / timestamp window / ...)
  -> adapter builds typed event struct (optional) + maps to canonical struct
  -> BullX.Gateway.publish_inbound(input, opts)
     1. InboundReceived.new/1 canonicalize + validate (§4.9)
     2. Security.verify_sender (§6.8) — failure returns {:error, {:security_denied, :verify, _, _}}, no mark_seen
     3. Deduper.seen?(source, id) — ETS hot path; hit returns {:ok, :duplicate}
     4. Construct SignalContext (§6.8)
     5. Gating.run_checks — failure returns {:error, {:policy_denied, :gating, _, _}}, no trigger_record
     6. Moderation.apply_moderators — :reject returns {:error, {:policy_denied, :moderation, _, _}};
        :modify replaces signal (re-runs §4.9 validation); :flag accumulates into extensions.bullx_flags
     7. Store.transaction { put_trigger_record(dedupe_key, envelope, published_at: nil) }
        — when the partial unique index (`published_at IS NULL`) hits a duplicate, the existing row is still unpublished:
           * existing.published_at != nil -> Deduper.mark_seen + return {:ok, :duplicate}
           * existing.published_at == nil -> proceed to step 8 and Bus.publish existing.signal_envelope
     8. Jido.Signal.Bus.publish(BullXGateway.SignalBus, [signal])
        — failure leaves trigger_record with published_at IS NULL; InboundReplay periodic sweep retries
     9. Store.update_trigger_record(id, published_at: now) + Deduper.mark_seen(key, ttl)
     10. Return {:ok, :published}
  -> adapter ack the external event according to the return (webhook 2xx / websocket ack / polling commit)
```

**Adapter ack contract (tightened):**

```elixir
case BullX.Gateway.publish_inbound(input) do
  {:ok, :published} -> ack              # persisted AND published to Bus
  {:ok, :duplicate} -> ack              # already recorded, adapter MUST ack
  {:error, _}       -> do_not_ack       # not persisted, external source MUST retry
end
```

**Duplicate and `published_at` — two complementary loops:**

1. **Synchronous loop (current request takes responsibility).** Step 7's `put_trigger_record` may hit the partial unique index when an earlier row for the same `dedupe_key` is still `published_at IS NULL`. The current `publish_inbound/1` call **does not return `:duplicate`**; instead it takes `existing.signal_envelope` and re-enters step 8 to `Bus.publish`. On success, it updates `published_at + mark_seen` and returns `{:ok, :published}`; on failure it returns `{:error, {:bus_publish_failed, _}}`. This guarantees that an external source's own retry is sufficient to repair a publish gap, without depending on a background reaper.
2. **Asynchronous loop (`InboundReplay` periodic sweep).** When the Bus is unavailable for an extended period or no further retries arrive, `InboundReplay` runs every 60 seconds (configurable), scanning `gateway_trigger_records WHERE published_at IS NULL AND inserted_at < now() - 30s` (the 30-second grace window avoids racing with in-flight requests), retrying `Bus.publish` for each row, and updating `published_at` on success. `InboundReplay` is **not boot-time only**: it runs once at boot, then on the periodic schedule, and supports an explicit trigger (`BullXGateway.ControlPlane.InboundReplay.run_once/0`) which Gateway internally invokes immediately after a `Bus.publish` failure to accelerate recovery.

Because `signal.id` is stable, downstream subscribers are idempotent on `signal.id`; the two loops overlapping cannot cause semantic duplication.

**Rejection-path persistence rules.** Security / Gating / Moderation failures **do not** write to `gateway_trigger_records` (so the external source has a chance to retry). All rejections are recorded via `:telemetry` (§6.8). Audit-grade "record every rejection" is the future `BullXGateway.AuditSink` behaviour's job and explicitly out of scope here.

### 6.6 `Webhook.RawBodyReader`

**Webhook is just a transport shell, not a business abstraction.** GitHub, Shopify, Stripe, DingTalk, Feishu have entirely different signature algorithms, payload structures, retry semantics, and event rendering. Gateway Core does not abstract these differences and does not define `BullXGateway.WebhookRequest` (raw body / headers / query / remote IP are adapter-internal concerns).

Each webhook source is its own adapter and **self-hosts its listener**: the listener is part of the adapter's `child_specs/2` subtree. Adapters may share library-level utilities (e.g. an HMAC verification helper), but those do not become Gateway Core protocol.

**However**, Gateway provides one strictly-scoped helper:

```elixir
BullXGateway.Webhook.RawBodyReader     # Plug body_reader implementation
# Usage: plug Plug.Parsers, body_reader: {BullXGateway.Webhook.RawBodyReader, :read_body, []}
```

It solves the mechanical problem that "Plug consumes the body by default, leaving downstream verifiers without the original bytes". It contains **no verification logic**. Adapters use it to obtain the raw body, then perform HMAC / JWT / any-algorithm verification themselves.

**`RawBodyReader` and the "Gateway Core does not depend on `Plug.Conn`" boundary.**

- **Gateway Core** (`BullXGateway` / `ControlPlane` / `Dispatcher` / `Adapter` behaviour / `Inputs.*` / signal modules / Security / Gating / Moderation behaviours) **does not depend on `Plug.Conn`** — the core runtime path contains no Plug types.
- **`BullXGateway.Webhook.RawBodyReader`** is an **optional adapter-support helper** placed under the `BullXGateway.Webhook` subnamespace; adapters `use` / `import` it inside their own webhook listeners on demand.
- **Compile-time dependency.** `plug` is declared as an **optional dependency** in `mix.exs` (`{:plug, "~> 1.14", optional: true}`). An adapter that uses `RawBodyReader` (or a host app like `BullXWeb`) declares `:plug` non-optional itself; environments without webhook adapters do not pull Plug into the compile closure.
- **Applicable scope.** Useful only for HTTP-webhook adapters (GitHub / Shopify / Stripe / Feishu webhook listeners). Long-polling / WebSocket / queue-consumer adapters do not need this helper.
- If a project does not want the Gateway app to carry any Plug optional dependency, `RawBodyReader` may be moved into `BullXWeb` or into a separate `bullx_gateway_webhook` package. This RFC keeps it under the Gateway subnamespace by default because the implementation is tiny (a few dozen lines).

**`RawBodyReader` (transport layer) vs. `Security.verify_sender` (platform layer).**

- `RawBodyReader` + adapter signature verification is a **transport-layer** check: did the external source actually send these bytes?
- `Security.verify_sender` is a **platform / business trust decision**: is this verified sender still allowed to enter?

The two coexist; neither overlaps nor replaces the other.

### 6.7 Degradation principles

Degradation is the adapter's responsibility. Gateway only insists on two hard boundaries:

1. **Gateway does not invent business fallback commands.** Runtime that wants to send a card must supply `fallback_text` (§5.2 hard contract); an adapter that does not support cards sends `fallback_text` and makes no business decisions.
2. **Degradation must be visible.** `Outcome.status = :degraded` and `warnings` records the reason (e.g. `"card_fallback_to_text"`).

The egress application of this rule is detailed in RFC 0003.

### 6.8 Policy pipeline

Gateway introduces **three pluggable pipeline hooks** — `Gating`, `Moderation`, `Security` — modelled after `jido_messaging`. **All defaults are empty.** Gateway itself ships no policy; the application wires modules into config.

**Guiding principle:** Gateway owns the carriage and the pipeline; the application owns the policy.

This RFC owns the unified pipeline definition because the inbound flow defines `Security.verify_sender`, the moderation behaviours, and the gating behaviour. The egress side reuses `Security.sanitize_outbound` (RFC 0003 references this section).

#### 6.8.1 Behaviour definitions

**`BullXGateway.Gating`:**

```elixir
defmodule BullXGateway.Gating do
  alias BullXGateway.SignalContext

  @type reason :: atom()
  @type description :: String.t()
  @type result :: :allow | {:deny, reason(), description()}

  @callback check(ctx :: SignalContext.t(), opts :: keyword()) :: result()
end
```

**`BullXGateway.Moderation`:**

```elixir
defmodule BullXGateway.Moderation do
  @type reason :: atom()
  @type description :: String.t()
  @type result ::
          :allow
          | {:reject, reason(), description()}
          | {:flag, reason(), description()}
          | {:modify, Jido.Signal.t()}

  @callback moderate(signal :: Jido.Signal.t(), opts :: keyword()) :: result()
end
```

A moderator receives the **already-rendered `%Jido.Signal{}`** (not a `BullXGateway.Inputs.*` struct). When it returns `:modify`, it must return a JSON-neutral signal that satisfies the §4.9 validation. Gateway re-runs the §4.9 validation on the modified signal; failure yields `{:error, {:moderation_invalid_return, module, detail}}`.

**`BullXGateway.Security`:**

```elixir
defmodule BullXGateway.Security do
  @type stage :: :verify | :sanitize
  @type input ::
          BullXGateway.Inputs.Message.t()
          | BullXGateway.Inputs.MessageEdited.t()
          | BullXGateway.Inputs.MessageRecalled.t()
          | BullXGateway.Inputs.Reaction.t()
          | BullXGateway.Inputs.Action.t()
          | BullXGateway.Inputs.SlashCommand.t()
          | BullXGateway.Inputs.Trigger.t()

  @callback verify_sender(
              channel :: {atom(), String.t()},
              input :: input(),
              opts :: keyword()
            ) :: :ok | {:ok, map()} | {:deny, atom(), String.t()} | {:error, term()}

  @callback sanitize_outbound(
              channel :: {atom(), String.t()},
              delivery :: BullX.Delivery.t(),
              opts :: keyword()
            ) :: {:ok, BullX.Delivery.t()} | {:ok, BullX.Delivery.t(), map()} | {:error, term()}
end
```

The shape borrows from `jido_messaging` but is BullX-specific: inputs are `BullXGateway.Inputs.*` canonical structs and `BullXGateway.Delivery`, not raw bodies or `incoming_message` types — Gateway is explicit about not touching raw bodies (§6.6).

**There is no `OutboundModeration` behaviour.** Outbound policy uses the single `Security.sanitize_outbound` hook (string truncation, URL stripping, emoji limits, etc.). Heavier content policy (tone, PII strip) belongs to the Runtime generation layer — applied where the LLM context is available.

**Rate limiting and PII redaction do not get dedicated behaviours.**

- Inbound rate limiting -> write a `Gating` module that returns `{:deny, :rate_limited, _}`.
- PII redaction -> write a `Moderation` module that returns `{:modify, redacted_signal}`.

#### 6.8.2 `BullXGateway.SignalContext`

The Gating context is derived from the rendered signal; gaters do not need to re-parse it.

```elixir
defmodule BullXGateway.SignalContext do
  @type t :: %__MODULE__{
    signal_type: String.t(),              # always "com.agentbull.x.inbound.received"
    event_category: atom(),               # :message | :message_edited | :message_recalled |
                                          # :reaction | :action | :slash_command | :trigger
    channel: {atom(), String.t()},
    scope_id: String.t(),
    thread_id: String.t() | nil,
    actor: %{id: String.t(), display: String.t(), bot: boolean(), app_user_id: String.t() | nil},
    duplex: boolean(),
    adapter_event_type: String.t(),
    adapter_event_version: integer(),
    agent_text: String.t() | nil,
    refs: [map()],
    signal: Jido.Signal.t()               # escape hatch
  }
end
```

This corresponds to jido_messaging's `MsgContext` but does not port `was_mentioned` / `agent_mentions` / `chat_type` / `command` — those are chat-domain semantics that the Gateway carrier layer does not recognise. Application code that needs them extracts from `adapter_event.data`.

**`event_category` is Gateway's; `adapter_event_type` is the adapter's** — together they give gaters / moderators two granularities for dispatch.

#### 6.8.3 Pipeline ordering

**Inbound (`publish_inbound/1`):**

```text
1. typed Signal canonicalize                 -> {:error, {:invalid_input, _}} on fail
2. Security.verify_sender                    -> {:error, {:security_denied, :verify, _, _}} on deny
                                                metadata merged into signal.extensions["bullx_security"]
3. Deduper.seen?(source, id)                 -> {:ok, :duplicate} returns here
4. Construct SignalContext
5. Gating.run_checks                         -> {:error, {:policy_denied, :gating, _, _}} on deny
6. Moderation.apply_moderators               -> {:error, {:policy_denied, :moderation, _, _}} on reject
                                                :flag accumulates into extensions["bullx_flags"]
                                                :modify replaces signal (re-validates §4.9)
7. Store.transaction puts gateway_trigger_records
8. Bus.publish(SignalBus, [signal])
9. Deduper.mark_seen(source, id)
10. {:ok, :published}
```

**Why Security comes before Dedupe but Gating / Moderation come after:**

- A Security failure (unauthorized sender) must not `mark_seen`. Once the sender is authorised, the next event must enter the pipeline.
- A Gating / Moderation failure means "this one is not handled". Letting Dedupe short-circuit first is more efficient (already decided once, no need to re-decide).
- `mark_seen` runs only at step 9 (after Bus.publish succeeds). On failure, no dedupe is recorded — so the external source's retry can still get through.

**Outbound (`deliver/1`)** — the unified pipeline that RFC 0003 implements:

```text
1. Delivery shape validation
2. Channel lookup
3. Capabilities pre-check (§6.2) — only op capability (:send | :edit | :stream)
4. Security.sanitize_outbound                -> {:error, {:security_denied, :sanitize, _, _}} on deny
5. OutboundDeduper.seen?(delivery.id)        -> hit republishes the cached success outcome
                                                (only terminal success is cached)
6. Store.put_dispatch (UNLOGGED)
7. ScopeWorker.cast
8. ScopeWorker invokes adapter.deliver / stream
9. Outcome normalised -> Attempt + Dispatch update + delivery.** publish + OutboundDeduper.mark_success on terminal success

DLQ replay path (RFC 0003): skips step 3 / step 5; jumps directly to step 6.
```

The egress steps run inside RFC 0003's `Dispatcher` / `ScopeWorker`. Their interaction with the Store is described in §7.4 below; the call sequence is owned by RFC 0003.

#### 6.8.4 Configuration

```elixir
config :bullx, BullXGateway,
  gating: [
    gaters: [MyApp.TenantAllowlist, MyApp.RateLimit],
    gating_opts: [tenant_file: "priv/tenants.json"],
    gating_timeout_ms: 50
  ],
  moderation: [
    moderators: [MyApp.PiiRedact, MyApp.BotEchoFilter],
    moderation_opts: [],
    moderation_timeout_ms: 100
  ],
  security: [
    adapter: MyApp.SecurityAdapter,
    adapter_opts: [],
    verify_timeout_ms: 50,
    sanitize_timeout_ms: 50
  ],
  policy_timeout_fallback: :deny,       # :deny | :allow_with_flag
  policy_error_fallback: :deny
```

Resolution priority (low to high): Gateway defaults (empty) -> app config -> per-call override (`publish_inbound(input, gating: [...])`).

**Ordering within a stage:** list order is execution order; the first `:deny` short-circuits; moderator `:modify` cascades; `:flag` accumulates; `:reject` short-circuits.

#### 6.8.5 Error handling

Each hook runs under `Task.Supervisor.async_nolink` + `Task.yield` (falling back to `Task.shutdown(:brutal_kill)` on timeout), against the `BullXGateway.PolicyTaskSupervisor` child of `BullXGateway.CoreSupervisor`. `async_nolink` is chosen so hook work is isolated from the caller's process; `BullXGateway.PolicyRunner` normalizes raised hook errors before the task exits so the caller can apply `policy_error_fallback` without polluting logs with expected task-crash reports. Defaults: a `raise` / timeout / invalid shape resolves through `policy_error_fallback` / `policy_timeout_fallback` (both default `:deny`).

A `:modify` returning an invalid shape produces `{:error, {:moderation_invalid_return, _, _}}`; the signal does not enter the Bus.

#### 6.8.6 Telemetry

Eleven pipeline-related telemetry events are emitted:

```text
[:bullx, :gateway, :security, :decision]
[:bullx, :gateway, :gating, :decision]
[:bullx, :gateway, :moderation, :decision]
[:bullx, :gateway, :publish_inbound, :start]
[:bullx, :gateway, :publish_inbound, :stop]
  metadata includes policy_outcome ::
    :published | :duplicate | :denied_security | :denied_gating | :rejected_moderation
[:bullx, :gateway, :publish_inbound, :exception]
[:bullx, :gateway, :deliver, :start]
[:bullx, :gateway, :deliver, :stop]
[:bullx, :gateway, :deliver, :exception]
[:bullx, :gateway, :store, :transaction]
[:bullx, :gateway, :inbound_replay, :sweep]
```

(The deliver-side decisions and per-attempt telemetry events that RFC 0003 emits are listed in that document; the `policy_outcome` tag and the eleven pipeline events listed here are the ones owned by this RFC.)

## 7. Runtime structure

### 7.1 Lifecycle and startup ordering

Gateway is Runtime's prerequisite infrastructure: `BullXGateway.CoreSupervisor` starts before `BullX.Runtime.Supervisor`. **There is no `IngressControl` global switch** — startup ordering is the ingress gate:

```text
BullX.Repo                                 # PostgreSQL connection; before Gateway
BullX.Config                               # see RFC 0001
BullXGateway.CoreSupervisor               # Bus + ControlPlane + Dispatcher + DLQ + Deduper
BullX.Skills.Supervisor
BullXBrain.Supervisor
BullX.Runtime.Supervisor                   # subscribes to SignalBus
BullXGateway.AdapterSupervisor            # the application attaches this child after Runtime is ready
```

**The durable ControlPlane buffers as well**: even if Runtime is late, inbound events have already been written to `gateway_trigger_records`. Once Runtime comes online and subscribes to the Bus, missed events are reapplied by the periodic `InboundReplay` (§7.9) sweep over `published_at IS NULL` — although in the normal path this is unnecessary, because Runtime subscribes before the inbound publish.

`BullXWeb.Endpoint` is the control-plane application's own startup item, not part of the Gateway contract.

### 7.2 Core supervision tree

```text
BullXGateway.CoreSupervisor
├── BullXGateway.ControlPlane            # GenServer; serializes Store reads/writes
├── BullXGateway.SignalBus               # Jido.Signal.Bus instance
├── BullXGateway.AdapterRegistry
├── BullXGateway.ScopeRegistry           # Registry (used by ScopeWorker names)               -- (RFC 0003)
├── BullXGateway.Dispatcher              # DynamicSupervisor of ScopeWorker                    -- (RFC 0003)
├── BullXGateway.Deduper                 # ETS hot cache + Store backing                       -- this RFC
├── BullXGateway.OutboundDeduper         # ETS 5-min TTL, outbound delivery.id dedupe          -- (RFC 0003)
├── BullXGateway.DLQ.ReplaySupervisor    # Registry + N ReplayWorker                           -- (RFC 0003)
├── BullXGateway.Retention               # hourly retention sweep                              -- this RFC migrates the inbound schedule
├── BullXGateway.ControlPlane.InboundReplay   # boot + periodic reaper (default 60 s)         -- this RFC
└── BullXGateway.Telemetry

BullXGateway.AdapterSupervisor           # attached by the application
└── per-channel adapter subtrees          # adapter.child_specs/2 returns the spec list
```

Children that this RFC implements: `ControlPlane`, `SignalBus`, `AdapterRegistry`, `Deduper`, `Retention`, `InboundReplay`, `Telemetry`, and `AdapterSupervisor` (as the empty supervisor whose children are attached when the application starts adapters).

Children supervised by `CoreSupervisor` but **implemented by RFC 0003**: `Dispatcher`, `ScopeRegistry`, `OutboundDeduper`, `DLQ.ReplaySupervisor`. They appear in the tree shape so the supervisor child list is complete and stable across both RFCs; their internal modules and behaviour are defined in RFC 0003.

(There is no `IngressControl`, no `AdapterHealth`.)

### 7.3 `Jido.Signal.Bus` usage

Plain publish / subscribe; no persistent subscriptions (durability is the ControlPlane's job, not Bus checkpoints):

```elixir
Jido.Signal.Bus.publish(BullXGateway.SignalBus, [signal])

Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.inbound.**",
  dispatch: {:pid, target: runtime_dispatcher}
)

Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.delivery.**",
  dispatch: {:pid, target: runtime_delivery_watcher}
)
```

### 7.4 ControlPlane, Store, and tables

`BullXGateway.ControlPlane` is the serialized entry point for all durable writes (a GenServer). The persistence layer is abstracted by the `Store` behaviour:

```elixir
defmodule BullXGateway.ControlPlane.Store do
  # --- inbound subset (this RFC implements) ---
  @callback put_trigger_record(map) :: :ok | {:error, :duplicate | term}
  @callback fetch_trigger_record_by_dedupe_key(String.t()) :: {:ok, map} | :error
  @callback list_trigger_records(filters :: keyword) :: {:ok, [map]}
  @callback update_trigger_record(id :: String.t(), changes :: map) :: :ok | {:error, term}
  @callback put_dedupe_seen(map) :: :ok | {:error, term}
  @callback fetch_dedupe_seen(key :: String.t()) :: {:ok, map} | :error
  @callback list_active_dedupe_seen() :: {:ok, [map]}
  @callback delete_expired_dedupe_seen() :: {:ok, non_neg_integer}
  @callback delete_old_trigger_records(before :: DateTime.t()) :: {:ok, non_neg_integer}
  @callback transaction((module() -> result)) :: {:ok, result} | {:error, term}

  # --- outbound subset (RFC 0003 implements) ---
  @callback put_dispatch(map) :: :ok | {:error, term}
  @callback update_dispatch(id :: String.t(), changes :: map) :: {:ok, map} | {:error, term}
  @callback delete_dispatch(id :: String.t()) :: :ok | {:error, term}
  @callback fetch_dispatch(id :: String.t()) :: {:ok, map} | :error
  @callback list_dispatches_by_scope(channel, scope_id, statuses) :: {:ok, [map]}
  @callback put_attempt(map) :: :ok | {:error, term}
  @callback list_attempts(dispatch_id :: String.t()) :: {:ok, [map]}
  @callback put_dead_letter(map) :: :ok | {:error, term}
  @callback fetch_dead_letter(dispatch_id :: String.t()) :: {:ok, map} | :error
  @callback list_dead_letters(filters :: keyword) :: {:ok, [map]}
  @callback increment_dead_letter_replay_count(dispatch_id :: String.t()) :: :ok | {:error, term}
end
```

The full behaviour signature lives in this RFC because the ControlPlane GenServer that hosts it is started by `CoreSupervisor` here. RFC 0003 implements the outbound subset of callbacks (and the matching tables).

**Sole implementation: `BullXGateway.ControlPlane.Store.Postgres`** (built on `BullX.Repo`). dev / test use the same PostgreSQL backend through the Ecto sandbox; no ETS backend is maintained, so the dev environment cannot drift from production. The behaviour abstraction exists for future pluggability and Mox-style unit tests, not for environment differentiation.

#### 7.4.1 Persistence strategy (whole table set)

The full Gateway schema spans five tables. This table is shown so the reader sees the whole picture; this RFC migrates only the inbound two; RFC 0003 migrates the outbound three.

| Table | PostgreSQL kind | Migrated by | Reason |
| --- | --- | --- | --- |
| `gateway_trigger_records` | **UNLOGGED** | this RFC | Gateway-layer audit; Runtime stores the business-semantics copy; losing this on crash does not break final consistency. |
| `gateway_dedupe_seen` | **UNLOGGED** | this RFC | Hot-cache backing; ETS rebuilds it after crash. |
| `gateway_dispatches` | **UNLOGGED** | RFC 0003 | Carries only in-flight deliveries; deleted on terminal outcome. Runtime's Oban job is the business-layer reliable source. |
| `gateway_attempts` | **UNLOGGED** | RFC 0003 | Per-attempt debug / telemetry; time-based retention (default 7 days), independent of dispatch lifecycle. |
| `gateway_dead_letters` | **LOGGED** (only one) | RFC 0003 | Ops needs manual replay; losing the failure trail is unacceptable. |

**Rationale.** The Gateway reliability boundary is "carrier-layer correctness" — *external events are not lost + outbound is not lost* — not "persist every intermediate state". Runtime (Oban) holds the business-layer retry semantics; adapters hold the external-source ack semantics. UNLOGGED tables provide transactional + unique-index semantics without writing to the WAL: an unclean server crash truncates them, Runtime re-issues outstanding work, the external source retries un-acked inbound events. The single exception is dead letters: failures that Gateway has given up on and that need human intervention must be durable.

Ecto migration style: UNLOGGED tables use `execute("CREATE UNLOGGED TABLE ...")` + `execute("DROP TABLE ...")`; LOGGED tables use the standard `create table(:gateway_dead_letters)`.

#### 7.4.2 Inbound table schemas (this RFC migrates)

**`gateway_trigger_records`** (UNLOGGED):

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` PK | Internal surrogate. |
| `source` | `text` | Adapter instance URI. |
| `external_id` | `text` | External stable event id. |
| `dedupe_key` | `text` | `sha256("#{source}|#{external_id}")`. Participates in the partial unique index `WHERE published_at IS NULL`. |
| `signal_id` | `text` | Final `signal.id`. |
| `signal_type` | `text` | Always `com.agentbull.x.inbound.received`. |
| `event_category` | `text` | One of the seven §4.3 values. |
| `duplex` | `boolean` | |
| `channel_adapter` | `text` | Denormalised. |
| `channel_tenant` | `text` | |
| `scope_id` | `text` | |
| `thread_id` | `text` nullable | |
| `signal_envelope` | `jsonb` | Full `%Jido.Signal{}` rendered as a string-key map. |
| `policy_outcome` | `text` | `published`. |
| `published_at` | `timestamptz` nullable | Set after Bus.publish succeeds. |
| `inserted_at` | `timestamptz` | |

Indexes:
- UNIQUE `(dedupe_key) WHERE published_at IS NULL`
- `(channel_adapter, channel_tenant, scope_id, inserted_at DESC)`
- `(published_at) WHERE published_at IS NULL`

**`gateway_dedupe_seen`** (UNLOGGED):

| Column | Type |
| --- | --- |
| `dedupe_key` | `text` PK |
| `source` | `text` |
| `external_id` | `text` |
| `expires_at` | `timestamptz` |
| `seen_at` | `timestamptz` |

#### 7.4.3 Outbound tables (RFC 0003 migrates; shape shown for completeness)

The outbound tables (`gateway_dispatches`, `gateway_attempts`, `gateway_dead_letters`) are migrated by RFC 0003. Their full schemas, including index definitions and the time-based retention rule for `gateway_attempts`, live in that document. This RFC does not migrate them, but the inbound runtime is aware of their existence (e.g. the Store behaviour signature spans both subsets, and the supervision tree includes the egress workers that read and write them).

### 7.5 Inbound `Deduper`

**`BullXGateway.Deduper`** (inbound) — ETS hot cache + `gateway_dedupe_seen` durable backing:

1. Gateway boot -> `Deduper.init/1` calls `Store.list_active_dedupe_seen()` to rehydrate ETS.
2. `publish_inbound/1` step 3 queries ETS.
3. Step 9 writes the Store first, then the ETS hot cache.
4. Sweep every minute: ETS local cleanup + `Store.delete_expired_dedupe_seen()`.
5. ETS-stale defense: when the ETS cache misses but an earlier row is still unpublished, the partial unique index on `gateway_trigger_records.dedupe_key WHERE published_at IS NULL` in step 7's `put_trigger_record` catches the duplicate. Defense in depth for the publish gap window.
6. **TTL is per-adapter** (configured via `AdapterRegistry`'s `:dedupe_ttl_ms`): Feishu 5 minutes, GitHub 72 hours, others per their RFCs; default 24 hours.

The outbound `OutboundDeduper` is a sibling process supervised under `CoreSupervisor` but defined and implemented in RFC 0003.

### 7.6 InboundReplay and Retention (inbound parts)

`BullXGateway.ControlPlane.InboundReplay` (periodic + on-demand):

- **Runs once at boot** (so pending trigger records are advanced immediately after a BEAM restart).
- **Then runs on a periodic schedule** (default 60 s, configurable; scans `WHERE published_at IS NULL AND inserted_at < now() - 30s`; the 30-second grace window avoids racing with in-flight `publish_inbound/1`).
- **Supports explicit triggering** (`run_once/0`); the `Bus.publish` failure path inside `publish_inbound/1` invokes it directly to accelerate recovery.
- For each pending record: `Bus.publish(signal_envelope)`. Success -> `update published_at`; failure -> leave for the next sweep.
- Because `signal.id` is stable, downstream is idempotent; the synchronous loop in §6.5 and this asynchronous loop overlapping cannot cause semantic duplication.

`BullXGateway.Retention` (hourly schedule, inbound responsibilities only — RFC 0003 owns the outbound rules):

- Delete `gateway_trigger_records.inserted_at < now - 7d`.
- Delete `gateway_dedupe_seen WHERE expires_at < now`.

The remaining retention rules (`gateway_attempts` 7-day time-based retention, `gateway_dispatches` immediate-delete on terminal, `gateway_dead_letters` 90-day retention) belong to RFC 0003.

## 8. Inbound pipelines

### 8.1 Feishu inbound: chat message -> Runtime

```text
Feishu push / WebSocket
  -> Feishu adapter listener (decryption / signature verification / self-echo filter)
  -> Feishu.Events.MessagePosted.from_raw(payload)
  -> mapped to %BullXGateway.Inputs.Message{event_category implied}
     - actor.id = "feishu:#{open_id}"
     - actor.app_user_id = resolver(open_id) | nil
  -> BullX.Gateway.publish_inbound(input)
     - Security.verify_sender (the application can plug in a tenant allowlist)
     - Deduper (source, id) check
     - Gating / Moderation (default empty)
     - Store.put_trigger_record (UNLOGGED)
     - Bus.publish
  -> Runtime dispatcher subscribes to "com.agentbull.x.inbound.**"
     - Agent prompt reads signal.data["agent_text"]
     - Machine routing reads signal.data["event_category"] + signal.data["adapter_event"]["type"]
```

### 8.2 GitHub webhook inbound -> Runtime / skill

```text
GitHub webhook HTTP POST
  -> GitHub adapter listener (uses BullXGateway.Webhook.RawBodyReader to obtain raw body
     + verifies X-Hub-Signature-256)
  -> select Events module by event header + payload:
       "issues" + action="opened" -> GitHub.Events.IssueOpened
       "pull_request" + action=*  -> GitHub.Events.PullRequestOpened / Merged / ...
  -> Events.from_raw(payload) -> typed event struct
  -> mapped to %BullXGateway.Inputs.Trigger{}
  -> BullX.Gateway.publish_inbound(input)
     -> {:ok, :published} | {:ok, :duplicate} -> respond 2xx
     -> {:error, _} -> respond 5xx so GitHub retries

Runtime / DevOps skill subscribes:
  case {signal.data["event_category"], signal.data["adapter_event"]["type"]} do
    {"trigger", "github.issue.opened"}        -> route_to_devops_agent(signal)
    {"trigger", "stripe.payment.succeeded"}   -> route_to_billing(signal)
    _ -> :skip
  end

Agent prompt still reads signal.data["agent_text"];
the skill takes signal.data["refs"] as tool arguments (calling the GitHub tool to comment on the issue).
```

Note: The GitHub adapter does not export `deliver/2` / `stream/3` (`capabilities/0` returns `[]` or only non-outbound capabilities). When Runtime wants to comment on a GitHub issue, it uses the GitHub tool / action that calls the GitHub REST API directly; **it does not go through Gateway `deliver/1`**. This is also why `duplex = false` and there is no `reply_channel`.

The matching outbound and stream pipelines (Runtime -> Gateway -> adapter, and the streaming card flow) are documented in RFC 0003.

## 9. Reliability (inbound parts)

The reliability story for the carrier layer:

1. **Adapter listeners are OTP-supervised.** Crashes auto-restart; a single adapter failure does not bring down the rest of Gateway.
2. **Startup order is the ingress gate.** Until Runtime is ready, `AdapterSupervisor` is not started and adapters do not consume.
3. **Durable inbound.** Inbound events are written to `gateway_trigger_records` (UNLOGGED transactional + partial unique index for unpublished rows) **before** the adapter acks the external source. After a crash, `InboundReplay` scans `published_at IS NULL` and re-publishes to the Bus.
4. (RFC 0003) Durable outbound attempts.
5. (RFC 0003) DLQ + manual replay.
6. **Short-lived dedupe.** `(source, id)` inbound dedupe (ETS + PostgreSQL UNLOGGED backing + the unpublished-row partial unique index on `gateway_trigger_records` — three layers of defense). The outbound `delivery.id` dedupe is an RFC 0003 concern.
7. **Telemetry.** Publish-failed / adapter-crashed / queue-length / pipeline-decision / retention-sweep events are emitted; the inbound-specific events listed in §6.8.6 are owned here.
8. **UNLOGGED crash semantics (inbound subset).** The two UNLOGGED tables this RFC migrates (`gateway_trigger_records`, `gateway_dedupe_seen`) are truncated on unclean server crash. This is acceptable: the external source retries un-acked events, Runtime re-issues outstanding work via Oban, and the LOGGED `gateway_dead_letters` table (RFC 0003) holds the failure record. The outbound UNLOGGED tables are described in RFC 0003 with the same crash semantics.
9. **Envelope-level durability framing.** Gateway does **not** provide `exactly-once`; that is a Runtime + Oban + business-persistence collaboration. Gateway provides **envelope-level durability + at-least-once with idempotent dedupe**.

The README's references to "high availability / exactly-once" are about agent workflow runtime guarantees, not Gateway-layer guarantees. The Gateway-layer guarantee is **envelope-level reliability**: not lost, queryable, replayable.

## 10. Non-goals

The cross-cutting non-goals (also enumerated in §2.2 for ergonomics; collected here as a standalone section):

**Business model / lifecycle:**

- Session / turn / conversation lifecycle.
- Memory / brain / knowledge graph.
- Command alias, approval, budget, HITL, subagent, cron, agent orchestration.
- "Interrupt agent on new message" concurrency control (Runtime).
- Think-block / reasoning content filtering (Runtime).

**Business modelling structs:**

- `%Room{}` / `%Participant{}` / `%Thread{}` / `%RoomBinding{}` / `%RoutingPolicy{}` are not introduced.
- No Gateway-level multi-adapter fan-out (Runtime calls `deliver/1` N times — see RFC 0003).
- No thread lifecycle, participant registry, presence, typing.
- The `scope_kind` enum was rejected (§4.8).
- `ModalClose` / `AssistantThreadStarted` (Slack-specific) are not modelled (folded into `Action` or ignored).

**Protocol-level:**

- Generic `WebhookAdapter` / unified `WebhookRequest` / raw_body / query / remote_ip abstraction (Gateway only ships `Webhook.RawBodyReader`, §6.6).
- `adapter_event` internal schema validation (the adapter's RFC + tests + fixtures own that).
- `failure_class` enum / retry taxonomy as a protocol contract (`error.kind` + `details.retry_after_ms` is a convention; Runtime decides retry policy — see RFC 0003).
- Bus persistent subscription / ack checkpoint (durability is the ControlPlane's job).

**Policy and reliability boundaries:**

- Audit-grade rejection persistence (rejections go to telemetry; future `BullXGateway.AuditSink`).
- Default Gating / Moderation / Security implementations (application-supplied).
- Outbound `Moderation` behaviour (outbound policy uses the single `Security.sanitize_outbound` hook).
- Approval state machine / HITL pause-resume (Runtime).

**Acceptable losses (carrier layer):**

- Mid-stream durability (only `stream_close` outcome durable; RFC 0003).
- Exactly-once business semantics (Runtime + Oban).
- UNLOGGED tables truncated on unclean server crash (Runtime / adapter / external source re-issue).

**Distribution and media:**

- Cross-node routing / distributed bus / global consistency (single-node constraint, §3.1).
- Media long-term storage / unified media cache (per-adapter).
- Album / multi-image re-batching (adapter-internal stateful normalization).
- Text metrics / chunking algorithms / media magic-bytes verification (adapter-internal).
- Cross-adapter bot-echo defense (no jido evidence, no real-world need).

**User identity:**

- No `ActorResolver` behaviour — IM-platform-identity to BullX-user-system resolution is an adapter-internal concern plus a future `BullX.Users` RFC. Gateway only reserves the `actor.app_user_id` slot.
- No onboarding / registration flow (synthetic actor fallback or rejection is Runtime's call).

**Outbound-specific non-goals** (enumerated in RFC 0003): no `notify_pid` channel, no Gateway-level multi-adapter fan-out for one Delivery, no `failure_class` retry taxonomy as a protocol contract.

## 11. Acceptance criteria (inbound side)

A coding agent has completed this RFC when all of the following hold. The numbering restarts at 1 for clarity within this RFC; RFC 0003 carries its own numbering for the egress side.

### 11.1 Dual projection contract + canonical category

1. Any `com.agentbull.x.inbound.received` signal's `data` contains a non-empty `agent_text` string, a `content` list, an `event_category` enum value, a `duplex` boolean, an `adapter_event.{type, version, data}` triple, an `actor.{id, display, bot}` triple, and a `refs` list (possibly empty); when `duplex = true`, `reply_channel.{adapter, tenant, scope_id, thread_id?}` is also present.
2. `data.event_category` is one of the seven enum values (`message` / `message_edited` / `message_recalled` / `reaction` / `action` / `slash_command` / `trigger`).
3. `data.duplex` is derived from `event_category`: six chat categories `true`, `trigger` `false`.
4. `BullXGateway.Inputs.*` structs may use atom-key maps / atom kinds; the final `%Jido.Signal{}`'s `data` and `extensions` must be string-key JSON-neutral maps.
5. A `%BullXGateway.Inputs.Trigger{adapter_event: %{type: "github.issue.opened", version: 1, data: %{issue_number: 101}}}` becomes `%{"adapter_event" => %{"type" => "github.issue.opened", "version" => 1, "data" => %{"issue_number" => 101}}}` in the published signal's `data`.
6. A source with no natural actor still supplies a synthetic actor (e.g. `%{"id" => "system:market-feed", "display" => "Market Feed", "bot" => true, "app_user_id" => nil}`).
7. `InboundReceived.new/1` fails when:
   - `agent_text` is missing or empty (and the category — reaction / recall — has not been default-rendered);
   - `content` is missing, not a list, or a block is not `%{"kind" => _, "body" => map}`;
   - `content.kind` is not in the six stable kinds;
   - non-`:text` `content.body["fallback_text"]` is missing or empty;
   - `event_category` is not in the seven values;
   - `duplex` is not boolean, or inconsistent with `event_category`;
   - `adapter_event.type` is missing or not a string; `adapter_event.version` is not an integer; `adapter_event.data` is not a map;
   - `actor.id` is empty; `actor.app_user_id` is neither nil nor a string;
   - `duplex = true` but `reply_channel` is missing or incomplete;
   - any category-specific required field is missing (e.g. `Reaction.target_external_message_id` / `emoji` / `action`).
8. `InboundReceived.new/1` does **not** fail when:
   - `adapter_event.type = "totally.unknown.event"`;
   - `adapter_event.data = %{}`;
   - `content = []`;
   - `content.body` carries fields beyond the §5.2 minimum;
   - `refs = []`;
   - `actor.app_user_id = nil`.

### 11.2 Bus routing

9. Subscribing to `"com.agentbull.x.inbound.**"` receives every inbound signal (regardless of `event_category`).
10. Subscribing to `"com.agentbull.x.delivery.**"` receives `delivery.succeeded` / `delivery.failed` (RFC 0003); inbound is not seen.
11. Gateway Core code contains no branch on a specific `adapter_event.type` value; Runtime dispatches by `data.event_category` + `data.adapter_event.type`.

### 11.3 Carrier / event / category layering

12. The same `inbound.received` carrier transports any `adapter_event.type` (`github.issue.opened`, `stripe.payment.succeeded`, `feishu.card.action_clicked`, ...); Gateway publishes and routes correctly.
13. Runtime dispatches based on `data.event_category` (coarse) + `data.adapter_event.type` (fine) and on `data.refs` for tool argument filling; Runtime does not extract structured fields from `agent_text`.
14. Gateway provides a dedicated `data["content"]` slot for carrier-level text / media / card; consumers do not have to parse `adapter_event.data` to read canonical content.

### 11.4 Ingress + Dedupe

15. `BullX.Gateway.publish_inbound/1` returns are distinguishable: `{:ok, :published}`, `{:ok, :duplicate}`, `{:error, reason}`.
16. The same GitHub delivery id arriving twice -> identical `(source, id)` -> within TTL, the second call returns `{:ok, :duplicate}`; the adapter ack both `:published` and `:duplicate`.
17. The Deduper may only `mark_seen` after `Bus.publish/2` succeeds; failure leaves no dedupe record.
18. After clearing the Deduper ETS and restarting, the durable `gateway_dedupe_seen` row still hits, so the second time the same id arrives -> `{:ok, :duplicate}`.
19. After `publish_inbound/1` returns `{:ok, :published}`, killing the BEAM and restarting still allows `gateway_trigger_records` to be queried by the corresponding `dedupe_key` row (within retention; the row predates the unclean server crash semantics for `UNLOGGED`, which only triggers on server crash, not BEAM crash).
20. Crash between `put_trigger_record` and `Bus.publish`: `InboundReplay` re-publishes; downstream sees the event exactly once because `signal.id` is stable and subscribers are idempotent.
21. **Per-adapter dedupe TTL.** TTL is read from each adapter's `AdapterRegistry` config (`:dedupe_ttl_ms`) and bounds the `(source, id)` window independently per adapter. With `dedupe_ttl_ms: 300_000` (5 minutes — Feishu default), the same `(source, id)` arriving 400 seconds later returns `{:ok, :published}`. With `dedupe_ttl_ms: 259_200_000` (72 hours — GitHub default), the same `(source, id)` arriving 24 hours later still returns `{:ok, :duplicate}`.

### 11.9 Policy pipeline

22. A gater returning `:allow` -> Bus receives the original signal.
23. A gater returning `:deny` -> `publish_inbound/1` returns `{:error, {:policy_denied, :gating, _, _}}`; Bus does not see the signal; Deduper is not marked.
24. A gater raising under `:deny` fallback -> same as (23). Under `:allow_with_flag` fallback -> `{:ok, :published}` with `extensions["bullx_flags"]` containing an `:error_fallback` flag.
25. A gater timeout is handled per `policy_timeout_fallback`.
26. A moderator returning `:reject` -> pipeline halts; Bus does not receive the signal.
27. A moderator returning `:flag` -> Bus receives the signal with the flag (`extensions["bullx_flags"]` accumulates).
28. A moderator returning `:modify` -> Bus receives the modified signal with `extensions["bullx_moderation_modified"] = true`.
29. A moderator `:modify` returning an invalid shape -> `{:error, {:moderation_invalid_return, _, _}}`.
30. `Security.verify_sender` returning `{:deny, _, _}` -> `{:error, {:security_denied, :verify, _, _}}`; Deduper is not marked (so the next event from a now-authorised sender can enter).
31. `Security.sanitize_outbound` (RFC 0003) stripping URLs -> the adapter receives the sanitized delivery, and `delivery.succeeded` reflects the sanitized content.
32. Pipeline ordering: a Security-denied event does **not** trigger Gating telemetry (short-circuit verification).
33. Dedupe fidelity: a Security-denied event re-arriving with the same id is still security-denied (not a duplicate); after a successful publish, the same id is `:duplicate`.
34. Zero defaults: with no `:bullx, BullXGateway` config, every Input passes through unchanged (no flag, no modify).
35. Telemetry events: the eleven pipeline events listed in §6.8.6 fire as specified.

### 11.10 Boundary isolation

36. Gateway Core code does not depend on `Plug.Conn`, does not define raw_body / query / remote_ip (`Webhook.RawBodyReader` is an optional helper, not part of the Adapter behaviour); GitHub / Shopify / Feishu webhook signature verification logic lives entirely inside the respective adapters.
37. Webhook listeners are self-hosted by their adapters; concrete webhook implementation details belong to the adapter's RFC, not to the Gateway Core RFC.
38. Gateway Core may use `BullX.Repo.*` (this RFC supersedes the original "no PostgreSQL" constraint) and may run PostgreSQL migrations; but **no `Oban.insert/1`** — Gateway does not schedule business-level jobs. (DLQ replay uses `BullXGateway.DLQ.ReplayWorker` partitioned workers, defined in RFC 0003, not Oban.)
39. Any inbound signal's `extensions` contains non-empty `bullx_channel_adapter` / `bullx_channel_tenant`; `scope_id` / `thread_id` live in `data` and are not duplicated into `extensions`.
40. **`subject` is human-readable only and not part of any routing path.** A signal whose `subject` has been deliberately scrambled (e.g. wrong adapter prefix, missing scope segment, garbled separator) must still be routed correctly by Runtime / subscribers consuming `extensions["bullx_channel_adapter"]`, `data["event_category"]`, `data["adapter_event"]["type"]`, and `data["refs"]`. No Gateway code path or documented consumer pattern parses `subject` for routing decisions.

(Outbound boundary criteria belong to RFC 0003.)

## Appendix A: `jido_signal` fact-check summary

Verified against the local source at `~/Projects/jido/jido_signal/lib`:

1. **`Jido.Signal.Bus.subscribe/3` routes by path pattern** — `jido_signal/lib/jido_signal/bus.ex`; pattern semantics come from `Jido.Signal.Router`.
2. **`Jido.Signal.new/1` may explicitly override `id`** — when `id` is omitted, `Jido.Signal.ID.generate!()` (UUID7) is invoked.
3. **`time` is an ISO8601 string** — `new/1` defaults to `DateTime.utc_now() |> DateTime.to_iso8601()`.
4. **`specversion` must be exactly `"1.0.2"`** — see `jido_signal/lib/jido_signal.ex:679-680`'s `parse_specversion/1`; other values (including `"1.0"`) return an error.
5. **`extensions` is a free-form map; only the `"dispatch"` / `"correlation"` namespaces are reserved** — BullX standardises on `bullx_*` prefixes.
6. **`Bus.publish/2` performs only structural validation; it does not mutate signals** — `jido_signal/lib/jido_signal/bus.ex:1149-1159`'s `validate_signals/1`.

(Earlier draft material on Bus persistent subscription ack-checkpoint details is no longer relevant; this RFC does not use persistent subscriptions, and durability is the ControlPlane's responsibility.)

## Appendix B: Dependency boundary

Gateway Core dependencies (introduced by this RFC; RFC 0003 inherits and adds nothing new):

- `:jido_signal` — event envelope + Bus.
- `:ecto_sql` + `:postgrex` — accessed through `BullX.Repo` for durable intake and (in RFC 0003) the DLQ.
- `:plug` — **optional dependency** (`{:plug, "~> 1.14", optional: true}`), required only by adapters that use `BullXGateway.Webhook.RawBodyReader` (§6.6). Adapters that do not need RawBodyReader omit it; environments without webhook adapters do not pull Plug into the compile closure.

Other dependencies (`Req`, WebSocket clients, specific source SDKs) are introduced by the corresponding adapter RFCs.

`BullX.Repo` itself is provided by the application (the existing BullX PostgreSQL connection); this RFC adds two new table migrations (both UNLOGGED). RFC 0003 adds three more (two UNLOGGED + one LOGGED).

## Appendix C: Consistency with `0000_Architecture.md`

`rfcs/plans/0000_Architecture.md`'s subsystem startup order is preliminary scaffolding.

This RFC clarifies:

- **Gateway Core is Runtime's prerequisite infrastructure** (`CoreSupervisor` starts before `Runtime.Supervisor`).
- **`Gateway.AdapterSupervisor` is attached by the application after Runtime is ready** (replacing the original `IngressControl` global switch with a flatter, more explicit mechanism).
- **Gateway requires `BullX.Repo`** (PostgreSQL connection) to be available before `CoreSupervisor`.
- The startup order is therefore adjusted from the draft "Runtime before Gateway" to "Repo -> Gateway.CoreSupervisor -> Runtime.Supervisor -> AdapterSupervisor".

The concrete code-level placement is performed in the implementation RFCs (this RFC and RFC 0003).

## Appendix D: BullX vs. jido ecosystem mapping

This RFC is the result of aligning BullX Gateway with the jido official trio (`jido_chat` + `jido_messaging` + `jido_integration`). The boundary mapping (full table; rows mentioning outbound concerns are flagged so the reader can navigate to RFC 0003):

| jido | BullX Gateway |
| --- | --- |
| `jido_chat` canonical event payload structs (`Incoming` / `ReactionEvent` / `ActionEvent` / `SlashCommandEvent`) | `BullXGateway.Inputs.*` — seven canonical category structs (§4.3 / §6.3); the library defines the standard event shape and adapters do the mapping |
| `jido_chat.Adapter.capabilities/0` | `BullXGateway.Adapter.capabilities/0` (§6.2) — declares supported ops |
| `jido_chat.Adapter.stream/3` | `BullXGateway.Adapter.stream/3` (§6.2; full egress contract in RFC 0003) — Enumerable stream; the adapter manages throttle / sequence / finalize |
| `jido_messaging.Gating / Moderation / Security` behaviours | `BullXGateway.Gating / Moderation / Security` (§6.8) — pluggable pipeline hooks; defaults empty |
| `jido_messaging.Deduper` + DLQ + replay | `BullXGateway.Deduper` (§7.5, this RFC) + `OutboundDeduper` + `gateway_dead_letters` + `ReplayWorker` (RFC 0003) — ETS hot cache + PostgreSQL durable backing |
| `jido_messaging.DeliveryPolicy.backoff` | `BullXGateway.RetryPolicy` + `Outcome.error.details["retry_after_ms"]` (RFC 0003) |
| `jido_integration.Ingress.admit_webhook` durable intake | `BullX.Gateway.publish_inbound/1` + `gateway_trigger_records` + `InboundReplay` (§6.5 / §7.6, this RFC) |
| `jido_integration.DispatchRuntime` (dispatch queue + retry + dead-letter) | `BullXGateway.Dispatcher` + `ScopeWorker` + `gateway_dispatches` + `gateway_attempts` + `gateway_dead_letters` (RFC 0003) |
| `jido_integration.ControlPlane` (durable run / attempt storage) | `BullXGateway.ControlPlane` + Store behaviour (§7.4, both inbound subset here and outbound subset in RFC 0003) — single PostgreSQL implementation; dev/test via Ecto sandbox |
| `jido_integration.WebhookRouter.verification` | **Not adopted** — each adapter does its own verification; Gateway only ships `Webhook.RawBodyReader` (§6.6) |
| `jido_integration.ConsumerProjection` generated Sensor / Plugin | **Not adopted** — BullX Runtime calls `Bus.subscribe` directly; no codegen |
| `jido_messaging.Room / Participant / Thread / RoomBinding / RoutingPolicy` | **Not adopted** — flat `{channel, scope_id, thread_id, actor + app_user_id, refs}` covers the surveyed IM / webhook scenarios (Feishu streaming / recall / edit / reaction / card action / group reply / multi-room / multi-tenant) |
| `jido_chat.ModalSubmitEvent / ModalCloseEvent` | **Not adopted** — Slack-specific; modal submit is folded into `Action` (§4.3) |

The spirit is consistent: **the carriage layer (including reliability) is small and stable, the domain layer is distributed and extensible, the policy layer is pluggable**. Differences in BullX Gateway:

1. **More than `jido_chat`:** durable inbound and outbound; DLQ + replay; pipeline hooks.
2. **Less than `jido_messaging`:** no Room / Participant / Thread business model (lives in Runtime); no persistent Session.
3. **Less than `jido_integration`:** no connector manifest, no generated Sensor, no cross-tenant auth lifecycle.
4. **Unique:** the `event_category` canonical classification (`message` / `message_edited` / `message_recalled` / `reaction` / `action` / `slash_command` / `trigger`) + the `duplex` axis + the `actor.app_user_id` identity slot — these are BullX's specialisations for IM / webhook hybrid scenarios.
