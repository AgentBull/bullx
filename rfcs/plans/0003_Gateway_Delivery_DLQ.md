# RFC 0003: Gateway Delivery + ScopeWorker + DLQ

- **Status**: Draft
- **Author**: Boris Ding
- **Created**: 2026-04-22
- **Supersedes**: `rfcs/drafts/Gateway.md` (jointly with RFC 0002)

## 1. TL;DR

This RFC specifies the **egress half** of `BullXGateway`: the protocol, runtime, durability, and operations surface that turn an internal `BullXGateway.Delivery` command into a confirmed effect on an external channel, together with the durable failure path (DLQ) and the manual replay surface that drives it.

The egress surface is defined by four primitives:

1. **`BullXGateway.Delivery`** — a single struct describing one outbound effect (`:send` / `:edit` / `:stream`), JSON-serializable except for the streaming Enumerable.
2. **`BullXGateway.Delivery.Outcome`** — the JSON-neutral result of one delivery, with three statuses (`:sent` / `:degraded` / `:failed`) and a Gateway-owned `error` map.
3. **Two outcome carrier signals** — `com.agentbull.x.delivery.succeeded` and `com.agentbull.x.delivery.failed` — published on `BullXGateway.SignalBus` so any subscriber can correlate by `data.delivery_id`.
4. **`ScopeWorker`** — one process per `{{adapter, tenant}, scope_id}` that serializes outbound work, owns the durable retry / DLQ state machine, and supervises the `:stream` Task.

Durability is provided by four PostgreSQL tables (`gateway_dispatches` UNLOGGED, `gateway_attempts` UNLOGGED, `gateway_dead_letters` LOGGED, plus a small egress slice of `Retention`), with replay driven by `BullX.Gateway.replay_dead_letter/1`.

The inbound carrier path, the `BullXGateway.Adapter` behaviour, the `AdapterRegistry`, the `SignalBus`, the policy hook behaviours (`Gating` / `Moderation` / `Security`), and the `ControlPlane` GenServer skeleton are defined in **RFC 0002**. This RFC consumes those primitives and adds everything needed for outbound delivery, including the outbound subset of the `Store` behaviour, the `ScopeWorker` runtime, the `OutboundDeduper`, the DLQ schema and ops API, and the egress slice of `Retention`.

`exactly-once` is not a Gateway guarantee. The Gateway provides **envelope-level at-least-once with `delivery.id` dedupe and durable terminal-failure capture**. Business-level exactly-once is the responsibility of `BullX.Runtime` (Oban) and the consuming subsystem.

## 2. Position and boundaries

### 2.1 What this RFC owns

1. The `BullXGateway.Delivery` struct, its `Content` value, and the `Outcome` projection (§5).
2. The `com.agentbull.x.delivery.succeeded` / `.failed` carrier signal envelope and `Outcome.to_signal_data/1` (§4).
3. The egress callbacks of `BullXGateway.Adapter` (`deliver/2` / `stream/3`) and the call contract that `ScopeWorker` follows when invoking them (§6).
4. The `BullX.Gateway.deliver/1` outbound pipeline (§6.3) and `BullX.Gateway.cancel_stream/1`.
5. The `ScopeWorker` runtime — keying, lifecycle, monitor of adapter subtree, retry classification, backoff, exception boundary, crash recovery (§7.5).
6. The `:stream` Task lifecycle and exit-reason mapping (§7.6).
7. The `OutboundDeduper` (terminal-success-only ETS cache + sweep) and its DLQ-replay bypass rule (§7.7).
8. The DLQ ops API and replay flow (§7.8).
9. The four outbound tables and their migrations (§7.4).
10. The egress slice of `Retention` (§7.9).
11. The egress acceptance criteria (§11).

### 2.2 What this RFC explicitly does **not** do

The carrier path for ingress, the `Inputs.*` family, `InboundReceived` typed signal module, `publish_inbound/1`, the `Deduper` for `(source, id)`, the `gateway_trigger_records` and `gateway_dedupe_seen` tables, the policy pipeline hook behaviours, and the `Webhook.RawBodyReader` helper are **defined in RFC 0002** and are not redefined here.

In addition, regardless of whether a topic touches ingress or egress, this RFC does not introduce any of the following (cross-cutting non-goals repeated only because they are load-bearing for understanding what `ScopeWorker` does and does not do):

- **No Gateway-level multi-adapter fan-out.** A Runtime that wants the same content delivered through two channels must call `BullX.Gateway.deliver/1` twice, with two distinct `delivery.id` values. `ScopeWorker` never duplicates work across channels.
- **No outbound `Moderation` behaviour.** Outbound policy is the single hook `Security.sanitize_outbound` (defined in RFC 0002). Heavier content shaping (tone, PII strip, persona) belongs in the LLM-context-aware Runtime layer, not in the egress carrier.
- **No `failure_class` enum and no retry taxonomy in the protocol.** The Gateway exposes `error.kind` plus the conventional `details.retry_after_ms` and `details.is_transient`. Runtime decides business-level retry meaning from those plus its own context.
- **No `:stream` mid-flight durability.** Only the close outcome is durable. A `:stream` `Dispatch` left in `:running` after a crash is dead-lettered with `error.kind = "stream_lost"`.
- **No exactly-once semantics.** That belongs to Runtime + Oban. The Gateway provides durable terminal-failure capture and at-least-once with `delivery.id` dedupe.
- **No audit-grade rejection persistence on the outbound side.** `Security.sanitize_outbound` denials are reported via telemetry and the synchronous return value; they are not written to PostgreSQL by this RFC.

## 3. Design constraints

The egress runtime adopts the same four constraints that govern the rest of the Gateway:

1. **Single-node.** No cross-node routing, no distributed bus, no global consistency. `ScopeWorker` and `OutboundDeduper` are local.
2. **PostgreSQL-backed durability.** Outbound state lives in `BullX.Repo`. Three of the four egress tables are `UNLOGGED` (transactional + uniquely indexed but not WAL-backed); only `gateway_dead_letters` is `LOGGED`. dev/test uses Ecto Sandbox; there is no ETS-backed `Store` implementation. (See §7.4 for the table-by-table rationale.)
3. **Process isolation per scope.** A failure in one `ScopeWorker` (or in the adapter it invokes) must not affect any other `{{adapter, tenant}, scope_id}`. Adapter exceptions are caught at the `ScopeWorker` boundary; adapter subtree DOWN events terminate only the in-flight `:stream` Tasks owned by the affected scopes.
4. **`BullXGateway.Delivery` is a struct distinct from inbound `Inputs.*`.** Outbound is not a mirror of inbound and is not modelled as a variant of `Jido.Signal`. The Delivery struct is the source-of-truth contract that Runtime constructs and the Gateway acts on.

Two further conventions apply throughout:

- **`Outcome` is JSON-neutral.** Status is a string in the wire form (`"sent"` / `"degraded"` / `"failed"`), `error` is a map with string keys, and `Outcome` itself never reaches `Jido.Signal.data` without going through `Outcome.to_signal_data/1`.
- **`time` is ISO8601.** All Gateway-produced signals use `DateTime.to_iso8601/1` for `time`, and `specversion` is exactly `"1.0.2"` (the parser rejects `"1.0"`).

## 4. Outcome carrier signals

The Gateway publishes two stable outcome `signal.type` values on `BullXGateway.SignalBus` (defined in RFC 0002):

```text
com.agentbull.x.delivery.succeeded         # data corresponds to Outcome{status: :sent | :degraded}
com.agentbull.x.delivery.failed            # data corresponds to Outcome{status: :failed}
```

Production timing:

- `:send` / `:edit` returning `{:ok, Outcome}` from `adapter.deliver/2` → publish `delivery.succeeded`.
- `:stream` reaching its close with `{:ok, Outcome}` from `adapter.stream/3` → publish `delivery.succeeded`.
- `:stream` cut short by adapter crash, explicit cancel, or Task shutdown → publish `delivery.failed` with `error.kind ∈ {"stream_lost", "stream_cancelled", "adapter_restarted"}`.
- Any op failing — unsupported callback, adapter `{:error, _}`, adapter exception, contract violation, or terminal classification after retries — → publish `delivery.failed`.

### 4.1 Envelope

```elixir
%Jido.Signal{
  specversion: "1.0.2",
  id: Jido.Signal.ID.generate!(),                        # one fresh UUID7 per outcome event
  source: "bullx://gateway/#{adapter}/#{tenant}",
  type: "com.agentbull.x.delivery.succeeded" | "com.agentbull.x.delivery.failed",
  subject: "#{adapter}:#{scope_id}#{if thread_id, do: ":#{thread_id}", else: ""}",
  time: DateTime.utc_now() |> DateTime.to_iso8601(),
  datacontenttype: "application/json",
  data: BullXGateway.Delivery.Outcome.to_signal_data(outcome),  # contains "delivery_id" key
  extensions: %{
    "bullx_channel_adapter" => Atom.to_string(adapter),
    "bullx_channel_tenant" => tenant,
    "bullx_caused_by" => delivery.caused_by_signal_id    # omitted when nil
  }
}
```

`subject` is human-readable only; routing must read `extensions` or `data`. `scope_id` and `thread_id` stay in `subject` and are not duplicated into `extensions`.

### 4.2 Why `signal.id ≠ delivery.id`

A single `delivery.id` may produce **multiple** outcome events across its lifetime — most commonly via DLQ replay: the first terminal failure publishes `delivery.failed{data.delivery_id: X}`, and a later successful replay publishes `delivery.succeeded{data.delivery_id: X}`. If both events shared a `signal.id`, Bus history, downstream idempotency, and traces would collapse two distinct events into one.

Therefore:

- **`signal.id`** identifies the outcome event itself. Each publish generates a fresh id via `Jido.Signal.ID.generate!/0`.
- **`data["delivery_id"]`** identifies which delivery the event belongs to. Subscribers correlate by `data.delivery_id` (and, if useful, by `extensions["bullx_caused_by"]`).

Same `delivery.id`, different `signal.id`. Multiple outcomes for one delivery are linked through `data.delivery_id`, but each event remains uniquely addressable in the Bus.

### 4.3 No `notify_pid`

The original draft of `BullXGateway.Delivery` carried a `notify_pid` to receive the outcome out-of-band. **This RFC removes `notify_pid`.** The single subscription contract is:

```elixir
Jido.Signal.Bus.subscribe(
  BullXGateway.SignalBus,
  "com.agentbull.x.delivery.**",
  dispatch: {:pid, target: my_observer}
)
```

Callers correlate received outcomes by `data.delivery_id` (preferred) or `extensions["bullx_caused_by"]` (when set from the inbound that triggered the delivery). This eliminates the dual-channel ambiguity ("did the result come back through my `notify_pid` or through the Bus?") and aligns the Gateway with the `jido_messaging` "synchronous return + Signal observer" pattern.

`BullX.Gateway.deliver/1` therefore never sends a result message to the caller's mailbox. It returns synchronously with `{:ok, delivery_id}` or an `{:error, _}` from the pre-flight stages, and any later progress is observed on the Bus.

## 5. Outbound protocol

### 5.1 `BullXGateway.Delivery`

```elixir
defmodule BullXGateway.Delivery do
  @type channel :: {adapter :: atom(), tenant :: String.t()}

  @type op :: :send | :edit | :stream

  @type t :: %__MODULE__{
          id: String.t(),
          op: op(),
          channel: channel(),
          scope_id: String.t(),
          thread_id: String.t() | nil,
          reply_to_external_id: String.t() | nil,
          target_external_id: String.t() | nil,
          content: BullXGateway.Delivery.Content.t() | Enumerable.t() | nil,
          caused_by_signal_id: String.t() | nil,
          extensions: map()
        }
end
```

Field semantics:

- **`id`** — caller-supplied identifier (UUID7 strongly recommended, e.g. `Uniq.UUID.uuid7/0`). Must be unique per intended effect; reused values are deduped to the original outcome (§7.7).
- **`op`** — one of `:send`, `:edit`, `:stream`. Must match a declared op-capability of the resolved adapter (§6.2).
- **`channel`** — `{adapter_atom, tenant_string}`. **`tenant` is always a `String.t()`**, never `term()`.
- **`scope_id` / `thread_id`** — same names as `data.scope_id` / `data.thread_id` on inbound signals and as the keys inside `data.reply_channel`. Runtime constructing a Delivery from an inbound reads `data.reply_channel` directly without renaming fields.
- **`reply_to_external_id`** — optional on `:send`. Means "reply to external message _X_". Adapters bridge platform-specific reply semantics (Feishu quote reply, Slack thread reply, etc.). If `thread_id` is also set, both fields are honored according to adapter contract.
- **`target_external_id`** — required for `:edit`. Identifies the external message to mutate.
- **`content`** —
  - For `:send` / `:edit`: a single `BullXGateway.Delivery.Content.t()` (§5.2), or `nil` for adapter-specific edits that carry intent in `extensions`.
  - For `:stream`: any `Enumerable.t()` of chunks. The shape of each chunk is adapter-internal; the Gateway does not interpret stream elements.
- **`caused_by_signal_id`** — the `signal.id` of the inbound that triggered this delivery. Optional but recommended; surfaces as `extensions["bullx_caused_by"]` on the outcome signal (§4.1).
- **`extensions`** — a free-form map of adapter-specific hints (e.g. Feishu `update_multi`). Not part of the outcome envelope.

**Removed in this RFC.** Two fields that earlier drafts carried are explicitly dropped:

- `notify_pid` — see §4.3.
- `stream_token` — the older two-op `:stream_open` / `:stream_chunk` protocol is collapsed into a single `:stream` op driven by `Enumerable`. Stream-internal sequence numbers, message ids, and card ids live entirely inside the adapter implementation; there is no protocol-level token.

#### 5.1.1 The `:stream` op durability boundary

The `content :: Enumerable.t()` of a `:stream` Delivery is a **process-local** value. It cannot be JSON-serialized, cannot be persisted into `gateway_dispatches.payload`, and cannot be reconstructed after a BEAM crash.

Concretely:

- When `ScopeWorker` writes a `:stream` Dispatch to `gateway_dispatches`, the `payload` jsonb column contains only **delivery metadata**: `op`, `scope_id`, `thread_id`, `reply_to_external_id`, `target_external_id`, `caused_by_signal_id`, and `extensions`. **`content` is not included.**
- The Enumerable lives only in memory, consumed by `ScopeWorker → adapter.stream/3`.
- If the BEAM (or the `ScopeWorker`) crashes while a `:stream` Dispatch is in `:running`, recovery does **not** rewrite the row to `:queued`. The Enumerable is gone and cannot be replayed. The recovery path instead writes a `gateway_dead_letters` row with `final_error.kind = "stream_lost"`, deletes the Dispatch, and publishes `delivery.failed` (see §7.5 crash recovery and §7.6).

This is the concrete realisation of "stream mid-flight is not durable, only the close outcome is" (§9.4).

### 5.2 `Content`

```elixir
defmodule BullXGateway.Delivery.Content do
  @type kind :: :text | :image | :audio | :video | :file | :card
  @type t :: %__MODULE__{kind: kind(), body: map()}
end
```

The `kind` enum and the per-kind minimum `body` shape are a **shared carrier contract** between outbound and inbound. The full body-shape table — including the **hard rule that every non-`:text` kind MUST carry a non-empty `body["fallback_text"]` string** — is normatively defined in **RFC 0002 §5.2** (the inbound `data["content"]` block contract). RFC 0003 reuses the same table verbatim for `BullXGateway.Delivery.Content.body`.

For orientation only, the six `kind` values are: `:text`, `:image`, `:audio`, `:video`, `:file`, `:card`. Media kinds carry a single `url` field (any URI scheme — `https://` or `data:`); the path / local-file abstraction is intentionally absent. Adapter implementations that receive byte buffers must upload or encode them into a URI before constructing a `Content`.

The `fallback_text` rule is what makes the degradation principle (§6.7) tractable: an adapter that does not natively support `:card` can always fall back to `body["fallback_text"]` and still satisfy the delivery, marking the outcome `:degraded`.

### 5.3 `Outcome`

```elixir
defmodule BullXGateway.Delivery.Outcome do
  @type success_status :: :sent | :degraded
  @type status :: success_status() | :failed

  @type t :: %__MODULE__{
          delivery_id: String.t(),
          status: status(),
          external_message_ids: [String.t()],
          primary_external_id: String.t() | nil,
          warnings: [String.t()],
          error: map() | nil
        }

  @type adapter_success_t :: %__MODULE__{
          delivery_id: String.t(),
          status: success_status(),
          external_message_ids: [String.t()],
          primary_external_id: String.t() | nil,
          warnings: [String.t()],
          error: nil
        }
end
```

Status semantics:

- **`:sent`** — the adapter confirms delivery to the external platform with no degradation.
- **`:degraded`** — the adapter delivered, but had to downgrade the content (e.g. `:card` rendered as `body["fallback_text"]`, media forwarded as a link rather than inline). `warnings` is non-empty (e.g. `["card_fallback_to_text"]`).
- **`:failed`** — the Gateway-owned terminal status. `error` is non-nil.

#### 5.3.1 Adapter success-path return contract

Adapter callbacks `deliver/2` and `stream/3` are restricted on the success path:

- Success: return `{:ok, %BullXGateway.Delivery.Outcome{}}` matching `adapter_success_t()` (`status ∈ {:sent, :degraded}`, `error: nil`).
- Failure: return `{:error, error_map}` (the `error_map` shape is specified below).
- **Forbidden**: `{:ok, %Outcome{status: :failed}}`. `:failed` is a Gateway-owned status that may only be produced by `ScopeWorker` after wrapping an error, exception, contract violation, or attempts-exhausted classification. If an adapter returns `{:ok, %Outcome{status: :failed}}`, `ScopeWorker` treats it as a contract violation: the outcome is normalized to `:failed` with `error.kind = "contract"` and the Dispatch is dead-lettered.

#### 5.3.2 `error` map

`error` must be a JSON-neutral map with string keys:

```elixir
%{
  "kind" =>
    "rate_limit"
    | "auth"
    | "network"
    | "payload"
    | "exception"
    | "unsupported"
    | "contract"
    | "stream_lost"
    | "stream_cancelled"
    | "adapter_restarted"
    | "unknown",
  "message" => "...",
  "details" => %{...}                                    # optional
}
```

Conventional `details` keys (non-mandatory; adapters fill them when available):

- **`details["retry_after_ms"]`** — adapter-suggested wait before the next retry (e.g. derived from a Feishu HTTP `Retry-After` header on a 429). When present, `ScopeWorker` **prefers this value over the default exponential backoff** for the next attempt. (§7.5 retry classification.)
- **`details["is_transient"]`** — adapter-asserted hint that the failure is transient. Runtime and `ScopeWorker` may consult it as additional context, but the protocol does not bind a specific behaviour to it.

**No `failure_class` enum.** The Gateway deliberately does **not** lift `:transient | :permanent | :ambiguous` (or any similar taxonomy) into the protocol:

- `ScopeWorker` performs a narrow, kind-based classification for retry-vs-terminal (§7.5). That classification is local to the Gateway and not exposed on the wire.
- Runtime decides business-level retry meaning from `error.kind`, `details`, and its own context. "Was a network read-timeout ambiguous?" is not a question the Gateway protocol answers.

Adapters are expected to swallow short-lived transient blips internally (e.g. one or two adapter-internal retries against a 503) and report only the final result to the Gateway.

#### 5.3.3 `Outcome.to_signal_data/1`

`Outcome` cannot be placed directly into `Jido.Signal.data` — the data field must be JSON-neutral. The Gateway projects it as follows:

```elixir
BullXGateway.Delivery.Outcome.to_signal_data(outcome) :: %{
  "delivery_id" => String.t(),
  "status" => "sent" | "degraded" | "failed",
  "external_message_ids" => [String.t()],
  "primary_external_id" => String.t() | nil,
  "warnings" => [String.t()],
  "error" => map() | nil
}
```

Success projection:

```elixir
%{
  "delivery_id" => "dlv_123",
  "status" => "sent",
  "external_message_ids" => ["msg_1"],
  "primary_external_id" => "msg_1",
  "warnings" => [],
  "error" => nil
}
```

Failure projection:

```elixir
%{
  "delivery_id" => "dlv_123",
  "status" => "failed",
  "external_message_ids" => [],
  "primary_external_id" => nil,
  "warnings" => [],
  "error" => %{
    "kind" => "rate_limit",
    "message" => "Feishu API 429 Too Many Requests",
    "details" => %{"retry_after_ms" => 3000}
  }
}
```

Notes:

- `signal.data["status"]` is a string, not an atom.
- The projection is also responsible for canonicalizing any atom-keyed `details` into string-keyed maps if an adapter constructs the error map with atoms.

### 5.4 Stream protocol

Stream is **one** op, not three. The shape is a single `:stream` Delivery whose `content` is an `Enumerable.t()`:

```elixir
%BullXGateway.Delivery{
  id: dlv_id,
  op: :stream,
  channel: {:feishu, "default"},
  scope_id: "oc_xxx",
  thread_id: nil,
  content: Stream.unfold(...)                 # any Enumerable of chunks
}
```

Adapter side:

```elixir
@callback stream(
            delivery :: BullX.Delivery.t(),
            enumerable :: Enumerable.t(),
            context :: BullXGateway.Adapter.context()
          ) :: {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}
```

The adapter consumes the Enumerable and is responsible for all platform mechanics (e.g. Feishu's `cardkit.v1.card.create` placeholder, `cardkit.v1.cardElement.content` incremental updates, `card.settings` finalize).

#### 5.4.1 Cancel vs. Interrupt

- **Cancel**: `BullX.Gateway.cancel_stream(delivery_id)` calls into the owning `ScopeWorker`, which executes `Task.shutdown(task, :brutal_kill)`. The adapter `stream/3` reducer **should** attempt a finalize when it receives `exit` (e.g. patch the card to "Cancelled" and return `{:error, %{"kind" => "stream_cancelled", ...}}`). If the adapter cannot finalize in time, `ScopeWorker` synthesizes the failure path (§7.6).
- **Interrupt**: there is no separate API. To soft-interrupt an in-flight stream, Runtime simply enqueues a new Delivery (typically `:edit` against the placeholder `target_external_id`). Same-scope serialization (§7.5) means the new Delivery is not executed until the stream completes; this gives a soft "follow-up replaces in progress" behaviour without a separate cancel.

#### 5.4.2 No protocol-level revision / snapshot

The Gateway does not know the shape of stream content and does not need to. Adapters that need to defend against out-of-order updates (e.g. Feishu's `sequence` parameter) maintain those internally and **do not leak them into `Outcome`**.

#### 5.4.3 Adapter-side stream UX responsibilities

Not protocol-binding, but the recommended adapter pattern. Implementations should:

1. **Placeholder first frame.** Before the first chunk arrives, post a placeholder external message ("Thinking…") and remember its `external_message_id`. This avoids a long visible silence.
2. **Throttling / coalescing.** LLM token rates exceed 100Hz; IM platforms accept ~10Hz updates. Adapters MUST debounce or coalesce internally (e.g. 100ms throttle with merged pending text).
3. **Platform idempotency.** Maintain whatever per-platform idempotency tokens are required (Feishu monotonic `sequence` + UUID v7, Slack `client_msg_id`, etc.) inside the adapter.
4. **Finalize.** On stream close, patch the message or card to a terminal form (e.g. Feishu `streaming_mode: false` and a summary populated from the first ~80 characters).
5. **Graceful cancel.** Honor `Task.shutdown` exits by attempting a best-effort finalize before returning `{:error, %{"kind" => "stream_cancelled"}}`.
6. **Platform rate-limit response.** Translate platform 429s into adapter-internal slowdown + bounded retry; do not surface every 429 to the Gateway as a top-level retryable error.
7. **Card structure.** For rich interactive streams, accept `delivery.content.kind = :card` as the initial card schema. Platforms with native client-side streaming animation (Feishu `streaming_config.print_frequency_ms`) place that configuration in the initial card payload. The Gateway treats card payloads as opaque.

## 6. Adapter egress contract

The full `BullXGateway.Adapter` behaviour is defined in **RFC 0002**, including `adapter_id/0`, `child_specs/2`, the `context()` type, and the two-axis `capabilities/0` (op-capabilities and metadata-capabilities). This section elaborates only what the egress runtime requires from those callbacks.

### 6.1 Egress callbacks

```elixir
@callback deliver(BullX.Delivery.t(), context()) ::
            {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}

@callback stream(BullX.Delivery.t(), Enumerable.t(), context()) ::
            {:ok, BullXGateway.Delivery.Outcome.adapter_success_t()} | {:error, map()}

@optional_callbacks [
  child_specs: 2,
  deliver: 2,
  stream: 3
]
```

Required at the runtime call site:

- The `context` passed by `ScopeWorker` carries at minimum `%{channel: BullX.Delivery.channel(), config: map(), telemetry: map()}` and may carry adapter-supplied additional keys (notably the adapter subtree anchor pid for `Process.monitor`, see §7.5).
- `deliver/2` handles `op = :send` and `op = :edit`. The adapter must declare `:send` and/or `:edit` in `capabilities/0`.
- `stream/3` handles `op = :stream`. The adapter must declare `:stream` in `capabilities/0`.
- An adapter that does not export the relevant callback **and** does not declare the corresponding op-capability is treated as not supporting that op. The egress pipeline detects this via `capabilities/0` (§6.3 step 3) without invoking an undefined callback.

### 6.2 Op vs. metadata capability semantics (egress)

The two-axis split established in RFC 0002 §6.2 has direct egress consequences:

- **Op-capabilities** (`:send | :edit | :stream`) are **one-to-one with `BullX.Delivery.op()`** and are the **only** capability axis that `BullX.Gateway.deliver/1` consults during pre-flight. If the resolved adapter does not declare the requested op, the pipeline immediately publishes `delivery.failed{error.kind = "unsupported"}` and writes `gateway_dead_letters` (§6.3 step 3).
- **Metadata capabilities** (`:reactions | :cards | :threads | …` — adapter-defined atoms) are **self-description for UI / Runtime / skill consumption only**. The Gateway **does not** pre-check them. Concretely, with the `:cards` example: a Runtime sends `Delivery{op: :send, content: %{kind: :card, …}}` to an adapter whose `capabilities/0` returns `[:send]` (no `:cards`). The Gateway **still casts** the Dispatch to `ScopeWorker` and invokes `adapter.deliver/2`. The adapter is expected to fall back to the card body's `body["fallback_text"]` and return `{:ok, %Outcome{status: :degraded, warnings: ["card_fallback_to_text"]}}`. **The only reason `deliver/1` rejects a `:send` is the absence of `:send` itself, never the absence of `:cards`.**

This is the load-bearing realisation of the degradation principle (§6.4): degradation is decided by the adapter against the `fallback_text` contract, not by the Gateway against a metadata-capability table.

### 6.3 The `deliver/1` outbound pipeline

```elixir
@spec BullX.Gateway.deliver(BullX.Delivery.t()) ::
        {:ok, delivery_id :: String.t()}
        | {:error, {:invalid_delivery, term()}}
        | {:error, {:unknown_channel, BullX.Delivery.channel()}}
        | {:error, {:security_denied, :sanitize, atom(), String.t()}}
```

Steps:

1. **Delivery shape validation.** Validate the struct fields (id non-empty, op ∈ `:send | :edit | :stream`, channel `{atom, string}`, scope_id non-empty, content shape matches op, etc.). On failure return `{:error, {:invalid_delivery, reason}}`. **Do not** publish `delivery.failed`. **Do not** write to PostgreSQL.
2. **Channel lookup** in `BullXGateway.AdapterRegistry` (RFC 0002). If the `{adapter, tenant}` pair is not registered, return `{:error, {:unknown_channel, channel}}`. **Do not** publish `delivery.failed`. **Do not** write to PostgreSQL.
3. **Capability pre-flight.** Read `adapter.capabilities/0`. If `delivery.op` is not declared: publish `delivery.failed{error.kind = "unsupported"}` (envelope per §4.1, with `data` produced by `Outcome.to_signal_data/1`) and write a `gateway_dead_letters` row capturing the original delivery as `payload`. Return `{:ok, delivery.id}`. (Note: the function still returns success because the failure has been observably recorded; the caller correlates by `data.delivery_id` on the Bus.) **Metadata-capabilities are not checked here** (§6.2).
4. **`Security.sanitize_outbound`.** Invoke the configured `Security` adapter (behaviour defined in RFC 0002). Possible outcomes:
   - `{:ok, sanitized_delivery}` → continue with `sanitized_delivery`.
   - `{:ok, sanitized_delivery, metadata_map}` → continue with `sanitized_delivery`; the metadata map is consumed by the policy pipeline and is otherwise opaque to the egress runtime.
   - `{:error, reason}` (or `:deny` shapes per the behaviour) → return `{:error, {:security_denied, :sanitize, reason_atom, description}}`. **Do not** write `gateway_dispatches`. **Do not** publish a `delivery.*` outcome (the synchronous return is the result; telemetry records the decision).
5. **`OutboundDeduper.seen?(delivery.id)`** (§7.7). The deduper caches **only terminal-success** outcomes. If the delivery.id is present:
   - Re-publish a `delivery.succeeded` carrying the cached outcome but with `warnings: ["duplicate_delivery_id"]` appended. The new `signal.id` is freshly generated (§4.2); `data.delivery_id` is the cached delivery.id.
   - **Do not** invoke the adapter.
   - Return `{:ok, delivery.id}`.

   If not present, continue.
6. **Resolve `RetryPolicy`** from the `AdapterRegistry` config for this channel (default `max_attempts: 5`, `base_backoff_ms: 1000`, `max_backoff_ms: 30_000`).
7. **`Store.put_dispatch/1`** with `%{id: delivery.id, status: :queued, attempts: 0, max_attempts: retry_policy.max_attempts, available_at: nil, payload: encode(delivery), …}` (UNLOGGED). On a unique-id conflict, treat as idempotent and return `{:ok, delivery.id}` without re-casting.
8. **Resolve `ScopeWorker`** via `BullXGateway.ScopeRegistry`, starting one under `BullXGateway.Dispatcher` (a `DynamicSupervisor`) if absent. The registry uses the `{:via, …}` lookup-or-start pattern atomically to avoid losing a cast across a `terminate` race.
9. **`GenServer.cast(scope_worker, {:enqueue, delivery.id})`.** The worker is responsible for re-reading the Dispatch from `Store` (it does not trust the cast payload to carry full state).
10. **Return `{:ok, delivery.id}`.**

**DLQ replay does not enter this pipeline.** `replay_dead_letter/1` (§7.8) directly performs `put_dispatch + cast ScopeWorker`, **skipping step 3 (capability pre-check) and step 5 (OutboundDeduper)**:

- Capability was already accepted at original enqueue. If a capability has since been removed from the adapter (e.g. `:cards` was dropped between enqueue and replay), degradation happens adapter-side via `fallback_text`, exactly as it would for a normal new delivery (§6.2).
- OutboundDeduper would be empty of this delivery.id (only terminal successes are cached), but skipping the lookup avoids a misclassification path entirely. (See §7.7 for the full bypass rationale.)

### 6.4 Degradation principles

Degradation is the adapter's responsibility. The Gateway enforces only two hard rules:

1. **The Gateway does not invent business fallback commands.** A Runtime that wants to send a card MUST provide `body["fallback_text"]` (§5.2 hard rule). An adapter that does not natively support cards delivers `fallback_text` as plain text. The adapter does not invent business-level fallback (e.g. it does not paraphrase, summarize, or restructure content).
2. **Degradation must be observable.** When degradation occurs, the adapter returns `Outcome{status: :degraded, warnings: [...]}` with at least one descriptive warning (`"card_fallback_to_text"`, `"audio_dropped_no_native_support"`, etc.). Silent degradation is a contract violation.

These two rules are what make the metadata-capability axis usable as a **hint** without making it a gating predicate.

## 7. Egress runtime

### 7.1 Lifecycle (recap)

The Gateway's startup ordering is fully specified in RFC 0002 §7.1. For the egress half, the relevant ordering is `Repo → Gateway.CoreSupervisor → Runtime.Supervisor → AdapterSupervisor`. `ScopeWorker` instances live under `BullXGateway.Dispatcher` (a `DynamicSupervisor` child of `CoreSupervisor`); they are started **lazily** on the first `deliver/1` for a given `{{adapter, tenant}, scope_id}`, plus a one-shot crash-recovery scan at boot (§7.5). They do not need `AdapterSupervisor` to be running in order to be started — the adapter is invoked through the registered module from `AdapterRegistry`, and a missing adapter subtree causes adapter callbacks to fail in the normal failure path.

### 7.2 Core supervisor children added by this RFC

The `BullXGateway.CoreSupervisor` tree defined in RFC 0002 (with the inbound children: `ControlPlane`, `SignalBus`, `AdapterRegistry`, `Deduper`, `ControlPlane.InboundReplay`, the inbound slice of `Retention`, and `Telemetry`) is extended by the following children for the egress half:

```text
BullXGateway.CoreSupervisor
├── … inbound children defined in RFC 0002 …
├── BullXGateway.Dispatcher              # DynamicSupervisor of ScopeWorker
├── BullXGateway.ScopeRegistry           # Registry; via tuple naming for ScopeWorker
├── BullXGateway.OutboundDeduper         # ETS + 5–10min TTL + sweep
├── BullXGateway.DLQ.ReplaySupervisor    # Registry + N partitioned ReplayWorker(s)
└── BullXGateway.Retention               # extended with egress sweep (see §7.9)
```

`BullXGateway.AdapterSupervisor` (the per-channel adapter subtrees produced by `adapter.child_specs/2`) sits outside `CoreSupervisor` and is started by the application after `Runtime.Supervisor` is ready, exactly as in RFC 0002.

Notes:

- **`Dispatcher`** is a `DynamicSupervisor` named `BullXGateway.Dispatcher`. It supervises one `ScopeWorker` per `{{adapter, tenant}, scope_id}` actually in use.
- **`ScopeRegistry`** is a `Registry` named `BullXGateway.ScopeRegistry` used as the via-tuple name source for `ScopeWorker` processes (`{:via, Registry, {BullXGateway.ScopeRegistry, {channel, scope_id}}}`).
- **`OutboundDeduper`** is a single GenServer owning a public ETS table, plus a periodic sweep timer (§7.7).
- **`DLQ.ReplaySupervisor`** is a small subtree (a `Registry` + `N` worker GenServers, partitioned by `:erlang.phash2/2`); see §7.8.
- **`Retention`** already exists from RFC 0002 for inbound retention; this RFC adds the outbound sweep responsibilities (§7.9).

### 7.3 ControlPlane Store: outbound subset

The `BullXGateway.ControlPlane.Store` behaviour is declared in RFC 0002 with both inbound and outbound callbacks (RFC 0002 implements only the inbound subset). The outbound subset that this RFC implements is:

```elixir
defmodule BullXGateway.ControlPlane.Store do
  # … inbound callbacks (see RFC 0002) …

  @callback put_dispatch(map()) :: :ok | {:error, term()}
  @callback update_dispatch(id :: String.t(), changes :: map()) :: {:ok, map()} | {:error, term()}
  @callback delete_dispatch(id :: String.t()) :: :ok | {:error, term()}
  @callback fetch_dispatch(id :: String.t()) :: {:ok, map()} | :error
  @callback list_dispatches_by_scope(channel :: BullX.Delivery.channel(),
                                     scope_id :: String.t(),
                                     statuses :: [atom()]) :: {:ok, [map()]}

  # put_attempt/1 is an id-keyed upsert.
  # First call for an id creates the running row (status: :running, started_at).
  # Later call(s) for the same id finalize it (status, finished_at, outcome | error).
  @callback put_attempt(map()) :: :ok | {:error, term()}
  @callback list_attempts(dispatch_id :: String.t()) :: {:ok, [map()]}

  @callback put_dead_letter(map()) :: :ok | {:error, term()}
  @callback fetch_dead_letter(dispatch_id :: String.t()) :: {:ok, map()} | :error
  @callback list_dead_letters(filters :: keyword()) :: {:ok, [map()]}
  @callback increment_dead_letter_replay_count(dispatch_id :: String.t()) :: :ok | {:error, term()}

  @callback transaction((-> result)) :: {:ok, result} | {:error, term()}
end
```

There is exactly one production implementation: `BullXGateway.ControlPlane.Store.Postgres`, backed by `BullX.Repo`. dev/test runs against the same Postgres adapter under Ecto Sandbox; there is no ETS-backed implementation. The behaviour is preserved for future pluggability and for Mox-based unit tests, **not** for environment differentiation.

### 7.4 Outbound table migrations

Three new tables are added by this RFC. Two are `UNLOGGED` (transactional + uniquely indexed but not WAL-backed; truncated on PostgreSQL server crash) and one is `LOGGED`. Migrations for the UNLOGGED tables use `execute("CREATE UNLOGGED TABLE ...")` paired with `execute("DROP TABLE ...")` for `down`. The LOGGED table uses standard Ecto `create table(...)`.

#### 7.4.1 `gateway_dispatches` (UNLOGGED)

Holds in-flight outbound deliveries only; rows are deleted on terminal success or on dead-letter.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | text PK | `delivery.id` |
| `op` | text | `"send" \| "edit" \| "stream"` |
| `channel_adapter` | text | denormalized for indexability |
| `channel_tenant` | text | |
| `scope_id` | text | |
| `thread_id` | text NULL | |
| `caused_by_signal_id` | text NULL | |
| `payload` | jsonb | encoded `BullXGateway.Delivery` minus `:stream` `content` (see §5.1.1) |
| `status` | text | `"queued" \| "running" \| "retry_scheduled"` (see below) |
| `attempts` | integer | last attempt sequence number occupied (`0` before the first attempt, `1` after the first) |
| `max_attempts` | integer | from resolved `RetryPolicy` |
| `available_at` | timestamptz NULL | NULL for `:queued` and `:running`; set for `:retry_scheduled` |
| `last_error` | jsonb NULL | last `error` map; informational |
| `inserted_at` | timestamptz | |
| `updated_at` | timestamptz | |

**`status` enum is restricted to three values.** It does **not** include `:completed` or `:dead_lettered`. Terminal success deletes the row outright (§7.5 step 4). Terminal failure writes a `gateway_dead_letters` row inside the same transaction and deletes the dispatch (§7.5 step 6).

Indexes:

- `(status, available_at)` — drives the per-scope crash-recovery scan and any dispatcher polling.
- `(channel_adapter, channel_tenant, scope_id, status, inserted_at)` — drives `list_dispatches_by_scope/3` and the per-scope worker startup scan.

The `id` PRIMARY KEY also enforces `delivery.id` uniqueness across in-flight Dispatches (a belt-and-suspenders against the OutboundDeduper, see §7.7).

#### 7.4.2 `gateway_attempts` (UNLOGGED)

One row per attempted invocation of an adapter callback for a given dispatch.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | text PK | `"#{dispatch_id}:#{attempt}"` |
| `dispatch_id` | text | foreign reference (no FK constraint; both tables are UNLOGGED) |
| `attempt` | integer | 1-based, monotonically increasing per `dispatch_id` |
| `started_at` | timestamptz | |
| `finished_at` | timestamptz NULL | NULL while `:running` |
| `status` | text | `"running" \| "completed" \| "failed"` |
| `outcome` | jsonb NULL | `Outcome.to_signal_data/1` projection on success |
| `error` | jsonb NULL | `error` map on failure |
| `inserted_at` | timestamptz | |

`Store.put_attempt/1` is an **id-keyed upsert**. The first call for an id writes `status: :running` with `started_at`. Subsequent call(s) for the same id finalize it by writing `finished_at` and the terminal `status / outcome / error`. This matches the contract documented in the inbound RFC and is the mechanism that lets ScopeWorker keep one row per attempt instead of two (one start, one end).

**Cross-DLQ-replay attempt-counter continuation.** `attempt` is a single monotonically increasing counter **per `delivery.id` lifetime**, not per Dispatch row. When a dead-letter is replayed (§7.8), `gateway_dispatches.attempts` is initialised from `gateway_dead_letters.attempts_total`, so the next attempt number is `attempts_total + 1`. `gateway_attempts.id` therefore continues the sequence: if the original Dispatch produced rows `dlv_X:1`, `dlv_X:2`, `dlv_X:3` and was dead-lettered with `attempts_total = 3`, the first replay attempt produces `dlv_X:4`. `gateway_dispatches.attempts` always holds the last-occupied number. (See §7.5 step 1 for the `next_attempt = attempts + 1` rule and §7.8 for the replay continuation.)

#### 7.4.3 `gateway_dead_letters` (LOGGED)

The single LOGGED outbound table. Holds terminally-failed Dispatches as durable failure evidence.

| Column | Type | Notes |
| --- | --- | --- |
| `dispatch_id` | text PK | same value as the original `gateway_dispatches.id` / `delivery.id` |
| `op` | text | |
| `channel_adapter` | text | |
| `channel_tenant` | text | |
| `scope_id` | text | |
| `thread_id` | text NULL | |
| `caused_by_signal_id` | text NULL | |
| `payload` | jsonb | the original Delivery payload (minus `:stream` Enumerable, per §5.1.1) |
| `final_error` | jsonb | the terminal `error` map |
| `attempts_total` | integer | cumulative attempt count for this `dispatch_id` across all replay rounds |
| `attempts_summary` | jsonb NULL | optional rollup of the last N error maps for human inspection |
| `dead_lettered_at` | timestamptz | |
| `replay_count` | integer DEFAULT 0 | incremented by `replay_dead_letter/1` |
| `archived_at` | timestamptz NULL | set by `archive_dead_letter/1`; excluded from normal `list_dead_letters/1` unless `include_archived: true` |

Indexes:

- `(channel_adapter, channel_tenant, scope_id, dead_lettered_at DESC)` — drives `list_dead_letters/1` filtered by channel and scope.
- `(dead_lettered_at DESC) WHERE archived_at IS NULL` — drives the default ops feed and the 90-day Retention sweep.

#### 7.4.4 Rationale for UNLOGGED vs. LOGGED

| Table | Persistence | Why |
| --- | --- | --- |
| `gateway_dispatches` | **UNLOGGED** | Holds only in-flight Dispatches; deleted on terminal success or dead-letter. The business source of truth is the Runtime's Oban job that issued the Delivery. Crash-truncate is recoverable: Runtime re-issues. |
| `gateway_attempts` | **UNLOGGED** | Per-attempt debug/telemetry detail. Time-based 7-day retention (independent of dispatch termination) so `list_attempts/1` keeps recent retry history available. Crash-truncate ≈ losing telemetry. |
| `gateway_dead_letters` | **LOGGED** | The unique LOGGED outbound table. Failure evidence that requires human action MUST survive a server crash; truncating these would lose the only durable record of "Gateway gave up". |

The UNLOGGED choice for the in-flight tables is a deliberate trade against per-row WAL cost. The Gateway's reliability boundary is **carrier-level correctness** (no inbound is dropped before the external source ack; no outbound terminal failure is dropped). It is **not** "every intermediate state is persisted across server crashes". Runtime + Oban is the business retry layer; the adapter is the external-source ack layer; UNLOGGED + the LOGGED dead-letter table is what the carrier actually owes.

### 7.5 Egress: `Dispatcher` + `ScopeWorker`

`ScopeWorker` is keyed by `{{adapter, tenant}, scope_id}`. Same key → serialized; different keys → independent and parallel.

#### 7.5.1 Responsibilities

- Serialize Dispatches for the same `{channel, scope_id}`.
- Track the `Task` ref of any in-flight `:stream` so it can be cancelled.
- `Process.monitor` the adapter subtree anchor pid (the adapter exposes this via `context`). On adapter subtree DOWN, terminate any in-flight `:stream` Task owned by this ScopeWorker.
- Catch any exception thrown by an adapter callback (§7.5.4) and produce a normalized `Outcome{status: :failed}`.
- Hibernate after 60s idle; terminate after 5 minutes idle. The `ScopeRegistry` via-tuple lookup-or-start handles the terminate-races (a delivery cast that arrives during termination starts a fresh worker).

#### 7.5.2 Crash recovery on `init/1`

Every ScopeWorker starts by reading its scope's pending Dispatches:

```elixir
{:ok, rows} = Store.list_dispatches_by_scope(channel, scope_id, [:queued, :retry_scheduled, :running])
```

The handling is split by row status and op:

- **`:queued` / `:retry_scheduled`** → schedule by `available_at` (`:queued` runs immediately; `:retry_scheduled` waits until `available_at`). These are the normal pending paths.
- **`:running` with `op = :send | :edit`** → treat as "crash interrupted". Rewrite to `:queued` with `available_at = now()`. The `attempts` counter is not changed; the next attempt classification handles convergence (an effectively-stuck Dispatch will hit `max_attempts` and be dead-lettered).
- **`:running` with `op = :stream`** → **do NOT rewrite to `:queued`**. The Enumerable is gone (§5.1.1). The recovery path is terminal:
  - Read the current `attempts` value `n`.
  - Inside `Store.transaction`: `put_attempt(%{id: "#{dispatch_id}:#{n}", status: :failed, finished_at: now, error: %{"kind" => "stream_lost", "message" => "Stream interrupted by crash; enumerable not durable"}})` + `put_dead_letter(%{dispatch_id: id, final_error: %{"kind" => "stream_lost", ...}, attempts_total: n, …})` + `delete_dispatch(id)`.
  - Publish `delivery.failed{error.kind = "stream_lost"}` on `SignalBus`.

In addition to per-worker `init/1`, the `ControlPlane` runs a **boot-time one-shot scan** that groups all `:queued` and `:retry_scheduled` rows by `{channel, scope_id}` and ensures a `ScopeWorker` is started for each group (so unattended Dispatches do not wait for a fresh `deliver/1` to wake their scope).

#### 7.5.3 Per-attempt execution

For each Dispatch the worker handles:

1. `next_attempt = attempts + 1`. `Store.update_dispatch(id, %{status: :running, attempts: next_attempt})`.
2. `Store.put_attempt(%{id: "#{dispatch_id}:#{next_attempt}", dispatch_id: dispatch_id, attempt: next_attempt, status: :running, started_at: now})`.
3. Invoke the adapter inside the exception boundary (§7.5.4):
   - `:send` / `:edit` → `adapter.deliver(delivery, context)`.
   - `:stream` → `Task.Supervisor.async_nolink(..., fn -> adapter.stream(delivery, enumerable, context) end)` and await the Task; see §7.6 for Task lifecycle.
4. **Success path.** Adapter returned `{:ok, %Outcome{status: :sent | :degraded}}`:
   - Inside `Store.transaction`: `put_attempt(%{id: "#{dispatch_id}:#{next_attempt}", status: :completed, finished_at: now, outcome: outcome_map})` and `delete_dispatch(id)`.
   - Publish `delivery.succeeded` on `SignalBus` (envelope per §4.1).
   - **`OutboundDeduper.mark_success(delivery.id, outcome)`** (the **only** place mark_success is called; see §7.7).
5. **Retryable failure.** Adapter returned `{:error, error_map}` classified as retryable AND `next_attempt < max_attempts`:
   - `put_attempt(%{id: "#{dispatch_id}:#{next_attempt}", status: :failed, finished_at: now, error: error_map})`.
   - Compute backoff (§7.5.5).
   - `update_dispatch(id, %{status: :retry_scheduled, available_at: now + backoff_ms, last_error: error_map})`.
   - `Process.send_after(self(), {:run, id}, backoff_ms)`.
6. **Terminal-or-exhausted failure.** Either retryable AND `next_attempt >= max_attempts`, or non-retryable:
   - Inside `Store.transaction`: `put_attempt(%{id: "#{dispatch_id}:#{next_attempt}", status: :failed, finished_at: now, error: error_map})`, `put_dead_letter(%{dispatch_id: id, final_error: error_map, attempts_total: next_attempt, payload: dispatch.payload, …})`, and `delete_dispatch(id)`.
   - Publish `delivery.failed` on `SignalBus`.
   - **Do not** mark `OutboundDeduper`.

#### 7.5.4 Adapter exception boundary

Every adapter call is wrapped:

```elixir
try do
  call_adapter(adapter, delivery, ctx)
rescue
  e -> {:error, %{"kind" => "exception", "message" => Exception.message(e)}}
catch
  kind, reason -> {:error, %{"kind" => "exception", "message" => "#{kind}: #{inspect(reason)}"}}
end
```

The result is fed back into the success / retryable / terminal classification. An adapter that raises is observationally indistinguishable from one that returned `{:error, %{"kind" => "exception", ...}}`. ScopeWorker itself does not crash on adapter exceptions.

#### 7.5.5 Retry classification and backoff

The default `BullXGateway.RetryPolicy`:

- **Retryable kinds**: `error.kind ∈ {"network", "rate_limit"}` plus `"exception"` and `"unknown"`.
- **Terminal kinds**: `error.kind ∈ {"auth", "payload", "unsupported", "contract"}`.
- **`stream_lost` and `stream_cancelled`** are terminal (no automatic retry). DLQ replay can still re-issue them, but there is no auto-retry for these.

Per-adapter `RetryPolicy` overrides may extend or restrict these sets; the `RetryPolicy` resolved in `deliver/1` step 6 is what `ScopeWorker` consults.

Backoff:

- If `error.details["retry_after_ms"]` is present, use it verbatim (capped at `max_backoff_ms`).
- Otherwise: `min(base_backoff_ms * 2^(attempts - 1), max_backoff_ms)`.
- Defaults: `base_backoff_ms: 1000`, `max_backoff_ms: 30_000`, `max_attempts: 5`.

### 7.6 Stream handling

For `op = :stream`, `ScopeWorker` uses `Task.async_nolink` so the adapter's blocking stream consumption does not block ScopeWorker's mailbox and does not link the failure modes to ScopeWorker's lifecycle:

```elixir
task = Task.Supervisor.async_nolink(
  BullXGateway.Dispatcher.TaskSupervisor,
  fn -> adapter.stream(delivery, enumerable, ctx) end
)
```

ScopeWorker stores the `task.ref` against `delivery.id`.

#### 7.6.1 Cancel

`BullX.Gateway.cancel_stream(delivery_id)`:

1. Look up the owning `ScopeWorker` via `ScopeRegistry`.
2. ScopeWorker calls `Task.shutdown(task, :brutal_kill)`.
3. The adapter's stream reducer **should** observe the `exit`, attempt a best-effort finalize (e.g. patch the placeholder card to "Cancelled"), and return `{:error, %{"kind" => "stream_cancelled", "message" => "..."}}`.
4. If the adapter cannot return in time, the Task exits with `:killed` / `:shutdown` (see §7.6.3) and ScopeWorker synthesizes the failure path.

#### 7.6.2 Adapter subtree DOWN via `Process.monitor`

ScopeWorker `Process.monitor`s the adapter subtree anchor pid that the adapter exposes through `context` (typically a per-channel supervisor pid registered by `child_specs/2`). On `{:DOWN, _ref, :process, _pid, _reason}`:

- For every in-flight `:stream` Task owned by this ScopeWorker: `Task.shutdown(task, :brutal_kill)`.
- The Task exit is then handled per §7.6.3.

#### 7.6.3 Task exit-reason mapping

ScopeWorker handles Task `:DOWN` messages:

- **`:normal` with `{:ok, %Outcome{}}`** → §7.5 step 4 (success path).
- **`:normal` with `{:error, error_map}`** → §7.5 step 5 or 6 (classification).
- **`:killed` / `:shutdown`** without an adapter return:
  - If `cancel_stream/1` initiated the shutdown → synthesize `{:error, %{"kind" => "stream_cancelled", "message" => "Adapter did not return before shutdown"}}` and route to step 6.
  - If a monitored adapter subtree DOWN initiated the shutdown → synthesize `{:error, %{"kind" => "adapter_restarted", "message" => "Adapter subtree DOWN during stream"}}` and route to step 6.

#### 7.6.4 Mid-flight is not durable; only close is

There is **no per-chunk persistence**. While `Dispatch.status = :running` for a `:stream`, no intermediate `gateway_attempts` rows are written for chunk-level progress; only one attempt row exists per Task lifetime, finalized on close (§7.5 step 4 or 6). This is the operating definition of "stream mid-flight is not durable, only the close outcome is" (§9.4).

### 7.7 `OutboundDeduper`

A dedicated GenServer owning a public ETS table, plus a periodic sweep timer.

- **Storage**: ETS, keyed by `delivery.id`, value `{outcome, expires_at}`.
- **TTL**: 5–10 minutes per entry (default 5 minutes; configurable per adapter via `AdapterRegistry`).
- **Sweep**: a periodic timer (default every 60s) deletes expired entries.

#### 7.7.1 The terminal-success-only rule

`OutboundDeduper` caches **only terminal success**. Concretely, the **only** moment that writes into the cache is `ScopeWorker` after a successful adapter call has been fully recorded:

> Inside the success path (§7.5 step 4), **after** `put_attempt(completed) + delete_dispatch + publish delivery.succeeded` have all completed, call `OutboundDeduper.mark_success(delivery.id, outcome)`.

Things that explicitly **do not** mark:

- `deliver/1` enqueue does not mark. Marking on enqueue would let DLQ replays be falsely shortcut as duplicates.
- Adapter failure (`{:error, _}` or normalized `Outcome{status: :failed}`) does not mark.
- Terminal dead-letter does not mark.
- `:retry_scheduled` does not mark (the in-flight retry has not produced a terminal success).

#### 7.7.2 Read path

`deliver/1` step 5 calls `OutboundDeduper.seen?(delivery.id)`. A hit is by construction a **terminal success**:

- Re-publish a `delivery.succeeded` carrying the cached outcome but with `warnings: ["duplicate_delivery_id"]` appended. The `signal.id` is freshly generated (§4.2).
- **Do not** invoke the adapter.
- Return `{:ok, delivery.id}` synchronously.

#### 7.7.3 DLQ replay bypass

`replay_dead_letter/1` (§7.8) **does not consult OutboundDeduper**. The justification is twofold:

- A hit in OutboundDeduper would always be a historical success. But the dispatch being replayed is by construction in `gateway_dead_letters`, i.e. a historical failure. The state cannot be both. Skipping the lookup avoids any chance of misclassifying "this delivery.id failed last time, now please retry" as "we already succeeded for this delivery.id".
- Replays should run end-to-end through the adapter exactly like a fresh attempt (modulo the skipped capability pre-check). After a successful replay, `ScopeWorker` marks OutboundDeduper as it does on any other terminal success.

#### 7.7.4 Belt-and-suspenders with `gateway_dispatches.id` UNIQUE

The `gateway_dispatches.id` PRIMARY KEY enforces one in-flight Dispatch per `delivery.id`. If a fresh `deliver/1` arrives with a `delivery.id` that is already in-flight (and so not yet in OutboundDeduper because no terminal success has happened), the unique-key conflict on `Store.put_dispatch/1` (§6.3 step 7) is the second line of defense, treated as idempotent. OutboundDeduper handles the post-success window; the unique key handles the in-flight window.

#### 7.7.5 No mark on inbound or outbound failure

For symmetry with the inbound path: failure-to-publish never leaves a positive dedupe trace. On the outbound side this means a failed adapter attempt or a terminal dead-letter never marks `OutboundDeduper`. A subsequent fresh `deliver/1` for the same `delivery.id` is therefore not misclassified as a duplicate; the `gateway_dispatches.id` uniqueness handles the in-flight collision.

### 7.8 DLQ + Replay

Four ops APIs:

```elixir
@spec BullX.Gateway.replay_dead_letter(dispatch_id :: String.t()) ::
        {:ok, %{status: :replayed, dispatch: map()}}
        | {:error, :not_found | term()}

@spec BullX.Gateway.list_dead_letters(opts :: keyword()) :: {:ok, [map()]}
# opts: :channel, :scope_id, :since, :until, :limit, :include_archived

@spec BullX.Gateway.archive_dead_letter(dispatch_id :: String.t()) :: :ok | {:error, term()}
@spec BullX.Gateway.purge_dead_letter(dispatch_id :: String.t()) :: :ok | {:error, term()}
```

`list_dead_letters/1` defaults to non-archived rows ordered by `dead_lettered_at DESC`. `archive_dead_letter/1` sets `archived_at = now()` (excludes the row from the default feed without deleting it). `purge_dead_letter/1` deletes the row outright (use rarely — this destroys the only durable failure evidence).

#### 7.8.1 `replay_dead_letter/1` flow

Routing: requests are dispatched to one of `N` `ReplayWorker` partitions by `:erlang.phash2({:replay, dispatch_id}, N)`. This bounds concurrency per-partition while letting independent dispatch_ids replay in parallel. The `DLQ.ReplaySupervisor` owns the partition workers and a `Registry` for routing.

On a replay request:

1. `Store.fetch_dead_letter(dispatch_id)`. If not present → `{:error, :not_found}`.
2. Inside `Store.transaction`:
   - `Store.put_dispatch(%{
       id: dispatch_id,
       status: :queued,
       attempts: dead_letter.attempts_total,            # continuation, not reset
       max_attempts: dead_letter.max_attempts || default,
       available_at: now(),
       last_error: nil,
       payload: dead_letter.payload,
       op: dead_letter.op,
       channel_adapter: dead_letter.channel_adapter,
       channel_tenant: dead_letter.channel_tenant,
       scope_id: dead_letter.scope_id,
       thread_id: dead_letter.thread_id,
       caused_by_signal_id: dead_letter.caused_by_signal_id
     })` — re-enters UNLOGGED `gateway_dispatches`. **`attempts` is initialised from `attempts_total`, not zero.** The next attempt issued by ScopeWorker is `attempts_total + 1`, preserving the cross-replay monotonic numbering for `gateway_attempts` rows.
   - `Store.increment_dead_letter_replay_count(dispatch_id)` — the dead-letter row is **preserved** as audit evidence; only `replay_count` is incremented.
3. Cast the `ScopeWorker` for `{channel, scope_id}` (start it if absent). The same code path as fresh `deliver/1` from this point onward, **except** capability pre-check is skipped (it was already passed at original enqueue) and OutboundDeduper is bypassed (§7.7.3). Degradation that becomes necessary because adapter capabilities have changed is handled adapter-side via `fallback_text` (§6.2).
4. Return `{:ok, %{status: :replayed, dispatch: dispatch_row}}`.

If a replay itself terminally fails, the new termination upserts the dead-letter row:

```sql
ON CONFLICT (dispatch_id) DO UPDATE
  SET final_error = EXCLUDED.final_error,
      attempts_total = gateway_dead_letters.attempts_total + (EXCLUDED.attempts_total - prior),
      dead_lettered_at = now()
```

`replay_count` is preserved (already incremented on entry) so the audit trail keeps growing across multiple replay rounds.

#### 7.8.2 Access control v1

This RFC does not implement authz on the DLQ ops. The functions are intended to be called from internal Gateway callers (BullXWeb operator console, REPL, ops tooling). The `BullXGateway` namespace reserves a `:bullx, :gateway_dlq_authz` callback hook for a future RFC to wrap these calls behind a real policy.

### 7.9 Retention (egress slice)

The `BullXGateway.Retention` GenServer (existing as of RFC 0002 for inbound retention) gains the egress sweep logic in this RFC. It runs hourly by default.

Egress operations:

- **`gateway_dispatches`** — no time-based sweep is needed in normal operation (rows are deleted immediately on terminal success or dead-letter). For belt-and-suspenders against orphaned `:retry_scheduled` rows whose ScopeWorker died without restarting (extremely rare given the boot-time recovery scan), Retention may delete rows older than 7 days; this is a backstop, not a primary path.
- **`gateway_attempts`** — time-based 7-day retention: `DELETE FROM gateway_attempts WHERE inserted_at < now() - interval '7 days'`. **Not** cascaded from dispatch deletion. This is deliberate: after a dispatch succeeds and is deleted, `list_attempts(dispatch_id)` should still return the recent retry history for ops debugging. Seven days is the default debug window.
- **`gateway_dead_letters`** — `DELETE FROM gateway_dead_letters WHERE dead_lettered_at < now() - interval '90 days' AND archived_at IS NULL`. Archived rows follow an independent policy (a separate operator-driven cleanup); the default is to keep them indefinitely.

The inbound retention rules (`gateway_trigger_records`, `gateway_dedupe_seen`) are defined in RFC 0002 and are not duplicated here.

## 8. Egress sequence walk-throughs

### 8.1 Reply pipeline (Runtime → Gateway → Adapter)

```text
Runtime constructs %BullXGateway.Delivery{}
  -> BullX.Gateway.deliver(delivery)
     - Delivery shape validation
     - Channel lookup (AdapterRegistry)
     - Capabilities pre-check (op-capability only; metadata-capabilities not consulted)
     - Security.sanitize_outbound
     - OutboundDeduper.seen?(delivery.id)
     - Store.put_dispatch (UNLOGGED)
     - ScopeWorker cast
  -> ScopeWorker executes
     - adapter.deliver(delivery, ctx)            for :send / :edit
     - adapter.stream(delivery, enumerable, ctx) for :stream (via Task.async_nolink)
  -> Success            : put_attempt(completed) + delete_dispatch + publish delivery.succeeded + OutboundDeduper.mark_success
  -> Failure (retryable): put_attempt(failed) + update_dispatch(retry_scheduled, backoff)
  -> Failure (terminal) : put_attempt(failed) + put_dead_letter (LOGGED) + delete_dispatch + publish delivery.failed
```

The canonical pattern for constructing a Delivery from an inbound signal's `data.reply_channel`:

```elixir
reply = inbound.data["reply_channel"]

if reply do
  channel = {String.to_existing_atom(reply["adapter"]), reply["tenant"]}

  %BullXGateway.Delivery{
    id: Uniq.UUID.uuid7(),
    op: :send,
    channel: channel,
    scope_id: reply["scope_id"],
    thread_id: reply["thread_id"],
    reply_to_external_id: nil,
    content: %BullXGateway.Delivery.Content{kind: :text, body: %{"text" => "..."}},
    caused_by_signal_id: inbound.id
  }
end
```

Note: `String.to_existing_atom/1` is used because the adapter atom must already exist in the running system (it was registered in `AdapterRegistry`). Construction never invents new atoms from inbound payload data.

### 8.2 Streaming reply pipeline (LLM token stream → Feishu streaming card)

```text
Runtime constructs %BullXGateway.Delivery{op: :stream, content: enumerable_of_chunks, ...}
  -> BullX.Gateway.deliver(delivery)
  -> ScopeWorker Task.async_nolink(fn -> Feishu.Adapter.stream(delivery, enumerable, ctx) end)
  -> Inside Feishu adapter:
     1. cardkit.v1.card.create with placeholder ("Thinking...")
     2. im.v1.message.create attaching card_id -> external_message_id
     3. Consume enumerable; 100ms throttle + merge pending text
     4. cardkit.v1.cardElement.content incremental updates (with monotonic sequence + UUID v7)
     5. enumerable closed -> cardkit.v1.card.settings(streaming_mode: false, summary)
     6. Return {:ok, %Outcome{status: :sent, external_message_ids: [om_xxx], primary_external_id: "om_xxx"}}
  -> ScopeWorker put_attempt(completed) + delete_dispatch + publish delivery.succeeded + OutboundDeduper.mark_success

Cancel path:
  Runtime calls BullX.Gateway.cancel_stream(delivery.id)
  -> ScopeWorker Task.shutdown(task, :brutal_kill)
  -> Adapter stream reducer observes exit -> attempts to patch card to "Cancelled"
                                           -> returns {:error, %{"kind" => "stream_cancelled"}}
  -> ScopeWorker put_attempt(failed) + put_dead_letter + delete_dispatch + publish delivery.failed

Soft-interrupt path:
  Runtime does NOT cancel; instead enqueues new %Delivery{op: :edit, target_external_id: om_xxx, content: new_content}
  -> The new Delivery is queued in gateway_dispatches
  -> Same-scope serialization holds the :edit until the :stream completes
  -> :edit then runs against the same external message
```

## 9. Reliability (egress slice)

The reliability framing established in RFC 0002 §9 carries over. The egress-relevant items are:

1. **Adapter listener supervision.** Adapter subtrees live under `BullXGateway.AdapterSupervisor` (RFC 0002). A crashed adapter restarts and its in-flight `:stream` Tasks are terminated via the `Process.monitor` path on each ScopeWorker; the resulting `Outcome{error.kind: "adapter_restarted"}` is dead-lettered. Egress of one adapter does not affect any other adapter's egress.
2. **Durable outbound attempts.** Every adapter call produces a `gateway_attempts` row (`status: :running` upsert at start, finalized at end). On terminal failure or attempts-exhaustion, a `gateway_dead_letters` row is written **inside the same transaction** that deletes the dispatch.
3. **DLQ + manual replay.** `BullX.Gateway.replay_dead_letter/1` re-queues a dead-lettered Dispatch under the same `delivery.id`, continuing the attempt counter from `attempts_total`. The dead-letter row is preserved (`replay_count` increments).
4. **Outbound dedupe.** `delivery.id` dedupe is enforced by two complementary mechanisms: `OutboundDeduper` (terminal-success-only ETS, 5–10 min TTL) and `gateway_dispatches.id` UNIQUE (in-flight defense). Failure paths never produce a positive dedupe trace.
5. **Telemetry (egress).** `delivery.succeeded`, `delivery.failed`, queue length per scope, ScopeWorker hibernate / terminate, OutboundDeduper hits / sweep, DLQ writes, replay outcomes, and Retention sweep counts all emit `:telemetry` events.
6. **UNLOGGED crash semantics (egress subset).** `gateway_dispatches` and `gateway_attempts` are UNLOGGED. On a real PostgreSQL server crash they are truncated. `gateway_dead_letters` is LOGGED and survives. The acceptable loss of in-flight Dispatches is covered by Runtime + Oban re-issue at the business layer.
7. **Envelope-level reliability framing.** The Gateway's outbound contract is **at-least-once with `delivery.id` dedupe and durable terminal-failure capture**. `exactly-once` is not a Gateway guarantee; it is a property the consuming subsystem builds on top of `delivery.id` correlation and outcome subscription.

## 10. Non-goals (egress)

- **No Gateway-level multi-adapter fan-out.** Runtime issues `N` `deliver/1` calls.
- **No outbound `Moderation` behaviour.** Outbound policy is the single hook `Security.sanitize_outbound`. (See §2.2.)
- **No `failure_class` enum in the protocol.** `error.kind` plus `details.retry_after_ms` / `details.is_transient` is all the protocol carries; classification is local to ScopeWorker. (See §5.3.2.)
- **No `:stream` mid-flight durability.** Only the close outcome is durable; mid-stream BEAM crash → `stream_lost` dead-letter. (See §5.1.1, §7.5.2, §7.6.4.)
- **No exactly-once semantics** at the Gateway. (See §9.7.)
- **No audit-grade rejection persistence on the outbound side.** `Security.sanitize_outbound` denials are reported via the synchronous return value and telemetry; they are not written to PostgreSQL by this RFC.
- **No `Oban.insert/1` from the Gateway.** Gateway does not schedule business-level jobs. DLQ replay uses partitioned `BullXGateway.DLQ.ReplayWorker`s, not Oban.
- **No `ActorResolver` / business identity bridging on egress.** Identity is set by Runtime when constructing the Delivery. `actor.app_user_id` is observed only on inbound (RFC 0002).

## 11. Acceptance criteria

A coding agent has completed this RFC when **all** of the following hold. Numbers are local to RFC 0003 and run from 1.

### 11.1 Delivery + Capability

1. `BullX.Gateway.deliver/1` returns `{:error, {:invalid_delivery, reason}}` for a malformed Delivery and **does not** publish `delivery.failed` and **does not** write any database row.
2. `BullX.Gateway.deliver/1` returns `{:error, {:unknown_channel, channel}}` for an unregistered `{adapter, tenant}` and **does not** publish `delivery.failed` and **does not** write any database row.
3. `BullXGateway.Adapter.capabilities/0` is a required callback. If the resolved adapter does not declare the requested op-capability (`:send | :edit | :stream`), `deliver/1` publishes `delivery.failed{error.kind = "unsupported"}`, writes a `gateway_dead_letters` row, and returns `{:ok, delivery.id}`.
4. Metadata-capabilities (`:cards | :reactions | :threads | …`) are **not** consulted by `deliver/1`. A Delivery with `op: :send, content: %{kind: :card, ...}` against an adapter declaring `[:send]` (no `:cards`) is cast to ScopeWorker; the adapter is expected to degrade via `fallback_text` and return `Outcome{status: :degraded}`.
5. `Security.sanitize_outbound` returning a deny shape causes `deliver/1` to return `{:error, {:security_denied, :sanitize, reason_atom, description}}`. No `gateway_dispatches` row is written. No `delivery.*` outcome is published.
6. `OutboundDeduper` caches **only terminal-success outcomes** (written by ScopeWorker after `put_attempt(completed) + delete_dispatch + publish delivery.succeeded`). Failed, in-flight, and `:retry_scheduled` Dispatches do not produce cache entries.
7. A `deliver/1` whose `delivery.id` hits `OutboundDeduper` re-publishes `delivery.succeeded` with `warnings: ["duplicate_delivery_id"]` (signal.id freshly generated per criterion 15), returns `{:ok, delivery.id}`, and **does not** invoke the adapter.
8. `replay_dead_letter/1` does **not** consult `OutboundDeduper`, so a historical failure being replayed cannot be misclassified as a duplicate success.
9. For `Delivery{op: :send | :edit}`: ScopeWorker invokes `adapter.deliver/2`. Adapter `{:ok, Outcome{status: :sent | :degraded}}` → `put_attempt(completed) + delete_dispatch + publish delivery.succeeded`. Adapter `{:error, error_map}` classified as retryable AND `attempts < max_attempts` → `:retry_scheduled` with backoff. Adapter `{:error, error_map}` classified as terminal OR `attempts` exhausted → `put_dead_letter + delete_dispatch + publish delivery.failed`.
10. Adapter success path is forbidden from returning `{:ok, Outcome{status: :failed}}`. Such a return is treated as a contract violation: ScopeWorker normalizes to `delivery.failed{error.kind = "contract"}` and writes `gateway_dead_letters`.
11. Every `Delivery.Content.kind` value satisfies the §5.2 minimum body shape (kind ∈ enum, body is a map, every non-`:text` kind has a non-empty `body["fallback_text"]` string). `:card` carries `format`, `payload`, `fallback_text`. Media kinds carry a single `url` URI string plus `fallback_text`. Extra fields are allowed.
12. `BullXGateway.Delivery` does **not** carry a `notify_pid` field. Outcome subscription is exclusively via `Bus.subscribe("com.agentbull.x.delivery.**")`. Outcome signals carry `extensions["bullx_caused_by"] = caused_by_signal_id` when the Delivery provided one.
13. When `Outcome.error.details["retry_after_ms"]` is present, ScopeWorker uses it (capped by `max_backoff_ms`) for the next retry instead of the exponential default.

### 11.2 Outcome Signal

14. `BullXGateway.Delivery.Outcome.to_signal_data/1` returns a JSON-neutral string-keyed map with `status` as `"sent" | "degraded" | "failed"` (string, not atom).
15. The `delivery.succeeded` and `delivery.failed` envelopes:
    - `id` is a fresh `Jido.Signal.ID.generate!/0` per outcome event (NOT the `delivery.id`), so multiple outcomes for the same `delivery.id` (e.g. failure then DLQ-replay success) have distinct `signal.id`s linked through `data["delivery_id"]`.
    - `source = "bullx://gateway/#{adapter}/#{tenant}"`.
    - `subject = "<adapter>:<scope>[:<thread>]"` (human-readable only; not parsed by routing).
    - `extensions` carries `bullx_channel_adapter` and `bullx_channel_tenant`. When `caused_by_signal_id` is set, `extensions["bullx_caused_by"]` is also present.

### 11.3 ScopeWorker + Stream

16. Deliveries with the same `{channel, scope_id}` are serialized; deliveries across different scopes run in parallel.
17. An adapter that raises (or `throw`s / `exit`s) inside `deliver/2` or `stream/3` does not crash ScopeWorker. ScopeWorker produces `Outcome{status: :failed, error: %{"kind" => "exception", ...}}` and follows the terminal path (`put_dead_letter + delete_dispatch + publish delivery.failed`).
18. `:stream` op: ScopeWorker uses `Task.async_nolink` to consume the Enumerable. Successful close produces `put_attempt(completed) + delete_dispatch + publish delivery.succeeded`.
19. `BullX.Gateway.cancel_stream(delivery_id)` calls `Task.shutdown(task, :brutal_kill)`. If the adapter returns `{:error, %{"kind" => "stream_cancelled"}}` in time, ScopeWorker takes the terminal path with that error. If the Task exits with `:killed` / `:shutdown` first, ScopeWorker synthesizes `error.kind = "stream_cancelled"` and takes the terminal path.
20. Adapter subtree DOWN observed via `Process.monitor` causes ScopeWorker to `Task.shutdown` any in-flight `:stream` and to take the terminal path with `error.kind = "adapter_restarted"`.
21. ScopeWorker hibernates after 60s idle and terminates after 5 minutes idle. `ScopeRegistry` via-tuple lookup-or-start is used to atomically restart a worker on a new cast that arrives during termination.

### 11.4 Durable + DLQ + Replay

22. **Outbound transient retry.** With a mock adapter that fails the first two attempts with `error.kind = "network"` and succeeds on the third: `deliver/1` returns `{:ok, id}`; `delivery.succeeded` is observed within ~5s; `Store.list_attempts(id)` returns three rows.
23. **Outbound exhaustion → DLQ.** With a mock adapter that always fails (`error.kind = "network"`) and `max_attempts = 3`: after the third failure, `gateway_dispatches` no longer contains the row, `gateway_dead_letters` contains exactly one row for it, `list_dead_letters/1` includes it, and `delivery.failed` was published.
24. **Terminal short-circuit.** With a mock adapter returning `error.kind = "auth"` on attempt 1: a `gateway_dead_letters` row is written immediately, the `gateway_dispatches` row is deleted, and no further attempts run.
25. **Outbound crash recovery.** After a `deliver/1` call, kill the BEAM. On restart, the UNLOGGED `gateway_dispatches` rows are gone (truncated by the absence of the previous server process — the precise crash mode is exercised by criterion 30); Runtime + Oban re-issues the work, producing a fresh `deliver/1` (with the same or a different `delivery.id` per Runtime's idempotency policy), which proceeds normally.
26. **DLQ replay success.** Starting from the state of criterion 23, switch the mock adapter to success and call `BullX.Gateway.replay_dead_letter(id)`. A new `gateway_dispatches` row appears with `attempts = dead_letter.attempts_total` (i.e. `3`, used as the continuation starting point). The replay attempt completes successfully; `delivery.succeeded` is observed; the `gateway_dispatches` row is deleted; the `gateway_dead_letters` row is preserved with `replay_count = 1`. `list_attempts(id)` returns four rows total with `attempt` values `1, 2, 3, 4`.
27. **DLQ replay missing id.** `replay_dead_letter("does_not_exist")` returns `{:error, :not_found}`.
28. **Per-adapter dedupe TTL** continues to apply on inbound (criterion in RFC 0002); the egress test exercises that `OutboundDeduper` TTL of 5 minutes does not retain entries past expiry — a successful Delivery with `delivery.id = X`, then 6 minutes later a second `deliver/1` with `delivery.id = X` invokes the adapter (no duplicate shortcut).
29. **Retention.** Manually invoking `BullXGateway.Retention.run_once/0` applies §7.9 cleanup for `gateway_attempts` (>7d) and `gateway_dead_letters` (>90d AND `archived_at IS NULL`).
30. **UNLOGGED crash semantics.** Simulate an unclean PostgreSQL **server** crash via `kill -9 <postmaster_pid>` / `docker kill -s KILL <pg_container>` / `pg_ctl stop -m immediate`. (`pg_terminate_backend` and `pg_cancel_backend` only kill an individual backend connection; they do **not** trigger a server-level crash and UNLOGGED tables are **not** truncated by them — the test must simulate a real server crash.) After the server restarts, all four UNLOGGED tables (`gateway_trigger_records` and `gateway_dedupe_seen` from RFC 0002, plus `gateway_dispatches` and `gateway_attempts` from this RFC) are empty; the LOGGED `gateway_dead_letters` retains all rows.

### 11.5 Boundary isolation

31. The Gateway egress code does not call `Oban.insert/1` (Gateway does not schedule business-level jobs). DLQ replay is implemented by partitioned `BullXGateway.DLQ.ReplayWorker` processes routed by `:erlang.phash2/2`, not by Oban.
32. `delivery.*` outcome signals may carry `extensions["bullx_caused_by"]`; envelope keys are restricted to those listed in §4.1 plus the per-RFC-0002 inbound provenance keys (no business payload is leaked into `extensions`).
33. The `context` map passed to `adapter.deliver/2` and `adapter.stream/3` always contains at minimum `%{channel: BullX.Delivery.channel(), config: map(), telemetry: map()}`. Adapters are free to read additional keys exposed by `child_specs/2` (for example, an internal subtree pid for `Process.monitor`), but the three required keys are guaranteed by the Gateway egress contract on every call.

If any criterion fails, the RFC is not complete.

## Appendix A: Dependency boundary

This RFC adds **no new package dependencies** beyond what RFC 0002 already requires. Specifically:

- `:jido_signal` (Bus + Signal envelope) — required by RFC 0002.
- `:ecto_sql` + `:postgrex` (via `BullX.Repo`) — already in scope before any Gateway RFC.
- `BullX.Repo` itself — provided by the application.

Adapter-specific HTTP clients, WebSocket clients, or platform SDKs (e.g. `Req`, Feishu / Slack / Discord SDKs) are introduced by per-adapter RFCs, not by this RFC.

This RFC adds three new database migrations (`gateway_dispatches` UNLOGGED, `gateway_attempts` UNLOGGED, `gateway_dead_letters` LOGGED). RFC 0002 owns the inbound migrations.

## Appendix B: Consistency with `rfcs/plans/0000_Architecture.md`

`0000_Architecture.md` notes that subsystem startup ordering in RFC 0 is scaffolding only and may be tightened by subsystem RFCs. This RFC does not change the high-level startup sequence beyond what RFC 0002 already establishes — the relevant order remains:

`BullX.Repo → BullXGateway.CoreSupervisor → BullX.Runtime.Supervisor → BullXGateway.AdapterSupervisor`.

The egress runtime additions of this RFC live under `BullXGateway.CoreSupervisor` (`Dispatcher`, `ScopeRegistry`, `OutboundDeduper`, `DLQ.ReplaySupervisor`, and the egress slice of `Retention`), so they come up with the rest of the Gateway core, before Runtime is ready and before any external adapter starts producing inbound traffic.

## Appendix C: Boundary mapping with the jido ecosystem (egress)

For the egress half of the Gateway, the alignment with the jido ecosystem (`jido_chat` + `jido_messaging` + `jido_integration`) is:

| jido | BullX Gateway (egress) |
| --- | --- |
| `jido_chat.Adapter.stream/3` | `BullXGateway.Adapter.stream/3` (§5.4 / §6.1) — Enumerable-driven; throttling, sequencing, finalize all live inside the adapter. |
| `jido_chat.Adapter.capabilities/0` | `BullXGateway.Adapter.capabilities/0` (RFC 0002 §6.2) — two-axis split (op vs. metadata); only op-capabilities gate `deliver/1` (§6.2). |
| `jido_messaging.Security.sanitize_outbound` | `BullXGateway.Security.sanitize_outbound` (behaviour from RFC 0002; egress invocation specified in §6.3 step 4). |
| `jido_messaging.DeliveryPolicy.backoff` | `BullXGateway.RetryPolicy` (§7.5.5) plus `Outcome.error.details["retry_after_ms"]` override (§5.3.2). |
| `jido_messaging.DLQ + replay` | `BullXGateway.DLQ.ReplaySupervisor` + `gateway_dead_letters` (LOGGED) + `replay_dead_letter/1` (§7.8). |
| `jido_integration.DispatchRuntime` (dispatch queue + retry + dead-letter) | `BullXGateway.Dispatcher` + `ScopeWorker` + `gateway_dispatches` + `gateway_attempts` + `gateway_dead_letters` (§7.5 / §7.8). |
| `jido_integration.ControlPlane` (durable run/attempt storage) | `BullXGateway.ControlPlane` Store outbound subset (§7.3) — single Postgres implementation, dev/test under Ecto Sandbox. |

Differences worth calling out:

1. The Gateway's egress is a **plain at-least-once carrier** with `delivery.id` dedupe. It does not borrow `jido_messaging`'s exactly-once message semantics — those belong to Runtime.
2. The two-axis `capabilities/0` (op vs. metadata) and the explicit "metadata-capabilities are not gating" rule (§6.2) are BullX-specific.
3. The `:stream` durability boundary (mid-flight is not durable; `stream_lost` is the explicit dead-letter outcome) is BullX-specific and is what makes UNLOGGED `gateway_dispatches` safe for the streaming case.
