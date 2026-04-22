# RFC 0006: Moduledoc Information Audit

- **Author**: Codex
- **Created**: 2026-04-23

## 1. TL;DR

This plan adds English `@moduledoc` only where the doc can contribute
information that is not already obvious from the code.

The target audience is an Elixir full-stack engineer with roughly three years
of experience who is new to BullX. The docs added by this plan must therefore
explain BullX-specific contracts, stage boundaries, assumptions, durable vs.
ephemeral truth, or protocol conventions. They must not restate OTP, Ecto,
Plug, ETS, or struct syntax that an experienced Elixir engineer already knows.

## 2. Scope

### 2.1 Modules to document

- `config/support/bootstrap.exs`
- `lib/bullx_gateway/adapter.ex`
- `lib/bullx_gateway/inputs.ex`
- `lib/bullx_gateway/json.ex`
- `lib/bullx_gateway/policy_runner.ex`
- `lib/bullx_gateway/gating.ex`
- `lib/bullx_gateway/moderation.ex`
- `lib/bullx_gateway/security.ex`
- `lib/bullx_gateway/signal_context.ex`
- `lib/bullx_gateway/signals/inbound_received.ex`
- `lib/bullx_gateway/deduper.ex`
- `packages/feishu_openapi/lib/feishu_openapi/spec.ex`
- `packages/feishu_openapi/lib/feishu_openapi/request.ex`
- `packages/feishu_openapi/lib/feishu_openapi/token_store.ex`
- `packages/feishu_openapi/lib/feishu_openapi/ws/protocol.ex`

### 2.2 Modules intentionally left undocumented

These modules stay on `@moduledoc false` because the code already says enough
and a module doc would mainly paraphrase implementation:

- thin `Supervisor` / `Application` wrappers with no extra BullX contract
- leaf input structs whose names, fields, and types are self-explanatory
- small helpers such as dedupe key hashing or webhook raw-body caching
- plain Ecto schemas whose fields do not hide extra business semantics

## 3. Cleanup plan

- **Dead code to delete**
  - None. This pass is documentation-only.
- **Duplicate logic to merge / patterns to reuse**
  - Reuse existing RFC context in `0001_Config`, `0002_Gateway_Inbound_ControlPlane`,
    and `0003_Gateway_Delivery_DLQ` rather than introducing new architectural
    explanations inside code comments.
  - Reuse the existing inline notes already present in `FeishuOpenAPI.Spec`,
    `FeishuOpenAPI.Request`, and `FeishuOpenAPI.TokenStore` by promoting them
    into concise `@moduledoc`.
- **Actual code paths / processes / schemas changing**
  - Only module documentation strings change.
  - No supervision tree, process state, schema, signal, or action semantics change.
- **Invariants that must remain true**
  - Every new `@moduledoc` must add non-obvious information.
  - No module should gain a doc that merely rewrites its function names or field list.
  - Existing `@moduledoc false` should remain in place when the code is already
    self-explanatory.
- **Verification commands**
  - `mix format`
  - `mix precommit`

## 4. Acceptance criteria

- Selected modules gain concise English `@moduledoc`.
- Each added `@moduledoc` explains at least one BullX- or package-specific
  contract, assumption, or stage boundary that a reader would not infer
  reliably from the code alone.
- Modules outside the scoped list are not changed unless formatting requires it.
