# RFC 0013: AIAgent LLM Model Endpoint Configuration

- **Author**: Boris Ding
- **Created**: 2026-04-29

## 1. TL;DR

This RFC brings `BullXAIAgent` and its underlying `req_llm` dependency under the `BullX.Config` boundary established by RFC 0001 and exemplified by RFC 0002 §6.8.4. The work falls into five concrete deliverables:

1. **A database-backed LLM provider catalog.** A new `llm_providers` table whose rows define complete LLM call endpoints — req_llm provider id, model id, optional `base_url`, optional encrypted API key, and a `provider_options` JSON map. Multiple rows may share the same underlying req_llm provider (for example, two OpenAI-compatible deployments behind different proxies). The catalog is the only source of provider auth and provider options inside BullXAIAgent; call sites do not define their own `api_key`, `base_url`, or `provider_options`.
2. **A reduced, fixed four-alias system.** `BullXAIAgent.ModelAliases` is rewritten so the allowed alias atoms are exactly `:default`, `:fast`, `:heavy`, and `:compression`. `:default` must be explicitly bound to a provider during /setup, otherwise `resolve_alias/1` returns `{:error, {:not_configured, :default}}` and the bang/model facade raises. Non-default aliases may bind directly to a provider or reuse another model alias; saves reject any circular alias dependency. When `:fast` or `:heavy` has no row, it reuses the resolved `:default` provider; when `:compression` has no row, it reuses the resolved `:fast` provider.
3. **API key encryption at rest.** API keys are stored encrypted in `llm_providers.encrypted_api_key`, never plaintext. Encryption uses XChaCha20-Poly1305 implemented as a new Rust NIF in `native/bullx_ext/`. The cipher key for each provider row is derived from `BULLX_SECRET_BASE` via the existing BLAKE3 KDF (`BullX.Ext.derive_key/3`), uniquely per provider id.
4. **Routing existing settings through `BullX.Config`.** Applicable `Application.get_env(:req_llm, …)` settings are replaced with declarations under `BullX.Config.ReqLLM`. The req_llm side is bridged to `Application.put_env(:req_llm, …)` so req_llm itself is not modified. Two req_llm settings are explicitly kept out of the bridge: `:load_dotenv` is hard-coded to `false` because BullX runs entirely off `BullX.Config`, and `:custom_providers` is added as Elixir code through a `BullXAIAgent.LLM.register_custom_providers/0` hook (no entries in this RFC). `BullXAIAgent.config/2` is deleted with no replacement; its only surviving call site (`agentic_loop_token_secret`) goes away with §5 below.

5. **Removing the unused Standalone Runtime feature.** `BullXAIAgent.Reasoning.AgenticLoop` carries a forked-from-jido_ai capability for resuming an in-flight loop across stateless calls via signed checkpoint tokens. BullX has no use case for it. The token machinery (`BullXAIAgent.Reasoning.AgenticLoop.Token`, the `:checkpoint` event token emission path, the `token_secret` config and action params, the `checkpoint_token` state field) is deleted. This eliminates the only remaining `BullXAIAgent.config/2` lookup, so no `BullX.Config.AIAgent` declaration module is introduced by this RFC.

This RFC also introduces `BullXAIAgent.Supervisor` and supersedes RFC 0000 §5.1's "AIAgent is namespace only" placement for AIAgent specifically. The new supervisor is the natural home for the catalog cache and for any future AIAgent runtime workers.

This RFC also extends the existing first-time `/setup` wizard with a new LLM model endpoint step that runs **before** the gateway-adapter step. The wizard becomes a four-phase flow: bootstrap activation → LLM model endpoints → gateway adapters → owner activation. Each phase has a clear "is this done?" predicate; `/setup` itself becomes a redirector that forwards to whichever phase is incomplete. Operator UI for managing LLM model endpoints and model aliases **after** setup (a full Web console) is deferred to a later RFC; the setup-time UI is sufficient to make the system usable.

### 1.1 Cleanup plan

- **Dead code to delete**
  - `BullXAIAgent.ModelAliases.@default_aliases` and the eight-alias compatibility code path are removed.
  - `BullXAIAgent.@default_llm_defaults` references to legacy model roles are reduced; all three roles default to `:default`.
  - `BullXAIAgent.Plugins.ModelRouting.@default_routes` references to `:capable`, `:thinking`, `:reasoning`, `:embedding` are rewritten in terms of `:default`, `:fast`, `:heavy`, `:compression`.
  - The `:image` and `:embedding` aliases are removed entirely; image generation will be modeled later as a function-calling skill, not a model alias.
  - `BullXAIAgent.config/2` is removed; after the Standalone Runtime cleanup below, it has zero call sites.
  - **Standalone Runtime removal** (legacy from the jido_ai fork — BullX has no use case):
    - `lib/bullx_ai_agent/reasoning/agentic_loop/token.ex` (entire `BullXAIAgent.Reasoning.AgenticLoop.Token` module).
    - In `BullXAIAgent.Reasoning.AgenticLoop.Config`: `@legacy_insecure_token_secret`, `@ephemeral_secret_key`, `@ephemeral_secret_warned_key`, the `token_secret` config field and surrounding load logic at `config.ex:133-139`, `normalize_token_secret/1`, `ephemeral_token_secret/0`, the `BullXAIAgent.config(:agentic_loop_token_secret, …)` lookup, and the related warning/error messages.
    - In `BullXAIAgent.Reasoning.AgenticLoop.Runner`: the `emit_checkpoint/5` helper and every call site that emits `:checkpoint` events. If observability of after-LLM / after-tools intermediate state is later wanted, add proper `:telemetry` events; this RFC does not.
    - In `BullXAIAgent.Reasoning.AgenticLoop.Strategy`: the `:checkpoint_token` state field, the `:checkpoint` runtime-kind branch, and any handling that relied on the token round-tripping into and out of state.
    - In `BullXAIAgent.Reasoning.AgenticLoop.Actions.{Start, Cancel, Continue, Collect}`: the `:token_secret` and `:checkpoint_token` parameter schemas; in `Collect`, the `params[:checkpoint_token]` decode branch (Collect now requires `:events`).
    - The `config_fingerprint/1` helper in `agentic_loop/config.ex` is deleted alongside if it has no remaining caller after token removal.
- **Duplicate logic to merge / patterns to reuse**
  - Reuse `BullX.Repo` and `BullX.Ecto.UUIDv7` for the new tables.
  - Reuse `BullX.Ext.derive_key/3` for per-provider key derivation; do not invent another KDF.
  - Reuse the `BullX.Config` DSL pattern established by `BullX.Config.Gateway` for `BullX.Config.ReqLLM`.
  - Reuse `BullX.Config.Cache` style (ETS-owned by a GenServer, refresh on writes) for `BullXAIAgent.LLM.Catalog.Cache`.
- **Code paths / schemas changing**
  - New tables `llm_providers` and `llm_alias_bindings`.
  - New modules under `lib/bullx_ai_agent/llm/`, including `ResolvedProvider`, `Provider`, `AliasBinding`, `Crypto`, `ProviderOptions`, `Catalog`, `Catalog.Cache`, and `Writer`.
  - New `BullXAIAgent.Supervisor` at `lib/bullx_ai_agent/supervisor.ex`.
  - New `BullXAIAgent.LLM` at `lib/bullx_ai_agent/llm.ex` exposing `register_custom_providers/0`.
  - New module `lib/bullx/config/req_llm.ex` (with companion bridge module). No `lib/bullx/config/ai_agent.ex` is added by this RFC.
  - New Rust source `native/bullx_ext/src/crypto/aead.rs` and matching declarations in `lib/bullx/ext.ex`.
  - `lib/bullx/application.ex` modified to start `BullXAIAgent.Supervisor`.
  - `lib/bullx/config/supervisor.ex` modified to add a synchronous boot-sync child after `BullX.Config.Cache`; the child runs `BullX.Config.ReqLLM.Bridge.sync_all!/0` during start and returns `:ignore`.
  - `config/config.exs` modified to add `config :req_llm, load_dotenv: false`.
  - `BullXAIAgent.ModelAliases`, `BullXAIAgent`, and `BullXAIAgent.Plugins.ModelRouting` rewritten as outlined above.
  - **Setup wizard restructure (§10):**
    - `lib/bullx_web/controllers/setup_controller.ex` modified into a phase-aware redirector.
    - `lib/bullx_web/controllers/setup_llm_controller.ex` (new) — owns `show`, `providers_check`, `providers_save`.
    - `lib/bullx_web/router.ex` modified to add `/setup/llm`, `/setup/llm/providers/check`, `/setup/llm/providers` and to point `/setup/gateway` at the existing `SetupGatewayController`.
    - `lib/bullx_web/controllers/setup_gateway_controller.ex` gains `show/2` for GET `/setup/gateway` and renders the existing gateway setup SPA at `setup/App`.
    - `webui/src/apps/setup-llm/App.jsx` (new) — LLM model endpoint list, add/edit sheet, model alias binding section, save.
    - i18n keys added under `web.setup.llm.*` (English + zh-Hans + ja).
- **Invariants that must remain true**
  - Process-local LLM catalog state is reconstructible from PostgreSQL.
  - The set of allowed alias atoms is `{:default, :fast, :heavy, :compression}` and is enforced both by Elixir guards and a database `CHECK` constraint. Declaring a fifth alias is a code change, not a runtime change.
  - `:default` has no code-level fallback and must bind directly to a provider. `resolve_alias(:default)` returns `{:error, {:not_configured, :default}}` when unbound, and `resolve_alias!/1` raises; the four-phase /setup wizard forces the operator to bind it before the system is usable.
  - Plaintext API keys never appear in `llm_providers` rows. They appear only transiently in the writer call frame, in `BullXAIAgent.LLM.Crypto.decrypt_api_key/2`, and in the DB-derived req_llm opts for a single request.
  - Alias resolution either returns `{:ok, resolved}` / `{:error, reason}` through `resolve_alias/1`, or raises with a descriptive error through `resolve_alias!/1`. There is no silent `nil` return.
  - `:default` cannot point at another alias. Non-default alias-to-alias bindings are allowed only when the effective alias graph is acyclic; implicit fallbacks participate in the same cycle check.
  - `BullXAIAgent.Supervisor` is the failure boundary for AIAgent runtime workers. It owns `BullXAIAgent.LLM.Catalog.Cache` in this RFC and will own future AIAgent workers (sub-agent pools, observation taps) without needing further supervision-tree changes.
  - `:load_dotenv` is `false` everywhere; `:custom_providers` is registered through code, not through `BullX.Config` or `Application.get_env(:req_llm, …)`.
- **Verification commands**
  - `mix test test/bullx_ai_agent/llm`
  - `mix test test/bullx/config/req_llm_bridge_test.exs`
  - `mix test test/bullx/ext_test.exs`
  - `mix precommit`

## 2. Scope

### 2.1 In scope

- Define the `llm_providers` and `llm_alias_bindings` tables and their Ecto schemas.
- Implement `BullXAIAgent.LLM.Catalog`, `BullXAIAgent.LLM.Catalog.Cache`, `BullXAIAgent.LLM.Crypto`, and `BullXAIAgent.LLM.Writer`.
- Add an `aead_encrypt/2` and `aead_decrypt/2` NIF to `bullx_ext` with XChaCha20-Poly1305.
- Rewrite `BullXAIAgent.ModelAliases` to enforce the fixed four-alias model and to consult the catalog for provider binding resolution.
- Rewrite `BullXAIAgent.@default_llm_defaults` to point all three kinds (`:text`, `:object`, `:stream`) at `:default`.
- Rewrite `BullXAIAgent.Plugins.ModelRouting.@default_routes` in terms of the four new aliases.
- Add the LLM model endpoint step to the `/setup` wizard (new `SetupLLMController`, new SPA app, route reordering so `/setup` redirects to the next unfinished phase).
- Delete the Standalone Runtime token machinery in `BullXAIAgent.Reasoning.AgenticLoop` and the `BullXAIAgent.config/2` shell. There are no surviving call sites after the deletion.
- Bring applicable `req_llm` settings under `BullX.Config.ReqLLM` and bridge them to `Application.put_env(:req_llm, …)` at boot and on writes.
- Test coverage for catalog resolution, provider-backed and alias-backed model alias bindings, encryption roundtrips, and the req_llm bridge.

### 2.2 Out of scope

- Multi-tenant scoping of providers (per-tenant aliases or per-tenant providers).
- Per-actor or per-skill provider override (callers may continue to pass an explicit `:model` per request — that pre-existing behavior is preserved without further extension).
- Failover, fallback chains, or weighted routing between providers.
- Cost tracking, usage metering, or budget enforcement.
- A general-purpose Web console for managing providers, alias bindings, or req_llm settings **after** setup. The setup-time wizard surface added by this RFC is the only operator UI; ongoing management still goes through `BullXAIAgent.LLM.Writer` directly until a follow-up Web RFC adds a control panel.
- Any form of `BULLX_SECRET_BASE` rotation. The master secret is treated as immutable for a deployment's lifetime. Rotation would invalidate every `encrypted_api_key` and is not supported in this RFC.
- Bridging provider-specific `req_llm` keys (`:anthropic_api_key`, `:azure_api_key`, etc.) into our catalog. These are subsumed by per-provider rows; BullXAIAgent always derives request auth/options from the resolved provider record.
- Bridging `req_llm` settings that are read once during req_llm's own application start, namely `:custom_providers` and `:load_dotenv`. `:load_dotenv` is hard-coded to `false` in compile-time `config/config.exs` because BullX runs entirely off `BullX.Config`. `:custom_providers` is added through Elixir code via `BullXAIAgent.LLM.register_custom_providers/0`; this RFC registers BullX-owned provider modules there.
- Migration of the six removed legacy alias atoms (`:capable`, `:thinking`, `:reasoning`, `:planning`, `:image`, `:embedding`) plus any historical `:fast` configuration shape to the new four-alias system. There is no compatibility shim. Callers in this repository are rewritten in lockstep.

## 3. Subsystem Placement

This RFC touches three top-level namespaces:

- **`BullXAIAgent.*`** (`lib/bullx_ai_agent/`) — gains `BullXAIAgent.Supervisor`, the `BullXAIAgent.LLM.*` provider-catalog modules, and a thin `BullXAIAgent.LLM` entry point that hosts `register_custom_providers/0`. `BullXAIAgent.Supervisor` supersedes RFC 0000 §5.1's "AIAgent is namespace only" placement for AIAgent specifically; it owns `BullXAIAgent.LLM.Catalog.Cache` today and is the explicit home for future AIAgent runtime workers.
- **`BullX.Config.*`** (`lib/bullx/config/`) — gains `BullX.Config.ReqLLM` (new declaration module, same DSL as `BullX.Config.Gateway`) and a companion `BullX.Config.ReqLLM.Bridge` plain module whose boot-time sync is invoked by a synchronous `BullX.Config.ReqLLM.BootSync` child under `BullX.Config.Supervisor`. No `BullX.Config.AIAgent` module is introduced.
- **`BullX.Ext`** (`lib/bullx/ext.ex` + `native/bullx_ext/`) — gains `aead_encrypt/2` and `aead_decrypt/2`, backed by a new `native/bullx_ext/src/crypto/aead.rs`.

`BullX.Config.ReqLLM.Bridge` is placed under `BullX.Config.Supervisor` because it is configuration infrastructure (it bridges `BullX.Config` to req_llm's `Application` env), not AIAgent runtime. RFC 0001 §7.3 already anticipates `BullX.Config.Supervisor` gaining additional children for exactly this reason.

The catalog tables are owned by `BullXAIAgent.LLM`, not by `BullX.Config`. They are domain entities, not free-form configuration rows; the `app_configs` key-value model is unsuitable for them. This is the same boundary RFC 0002 §6.8.4 draws between Gateway adapter rows (operator-managed entities) and runtime scalar settings.

## 4. Concept Overview

### 4.1 Provider

A **provider** is a complete LLM call endpoint: a req_llm provider id, a model id, optional `base_url`, an optional `api_key`, and an optional `provider_options` map. A provider is identified by an operator-chosen `name` (a unique short string) and by an internal UUID primary key.

A provider's resolved form is a BullX-owned struct that carries the two values req_llm needs: a `ReqLLM.model_input/0` model spec and request opts. The struct is not a second configuration surface; every field is derived from the `llm_providers` row at resolution time.

```elixir
%BullXAIAgent.LLM.ResolvedProvider{
  model: %{
    provider: :openai,
    id: "kimi-k2.5",
    base_url: "https://proxy.example.com/v1"
  },
  opts: [
    api_key: "sk-...",
    provider_options: %{oauth_file: "/run/secrets/openai-codex.json"}
  ]
}
```

`api_key` and `provider_options` are request opts because that is the contract req_llm exposes. BullXAIAgent facades unwrap the struct immediately before calling req_llm. Call-level BullXAIAgent opts may still carry generation controls such as `:temperature`, `:max_tokens`, `:timeout`, `:tools`, and `:tool_choice`; they must not carry provider configuration keys (`:api_key`, `:base_url`, or `:provider_options`).

A provider is operator-managed and lives in `llm_providers`. There is no built-in catalog of providers; operators populate the table.

### 4.2 Alias

An **alias** is one of exactly four atoms: `:default`, `:fast`, `:heavy`, `:compression`. The set is closed and statically enforced.

Every alias row is operator-managed and lives in `llm_alias_bindings`. `:default` binds directly to a provider and cannot point at another alias. `:fast`, `:heavy`, and `:compression` may bind directly to a provider or reuse another model alias. The writer and setup controller reject circular alias dependencies before persistence. When `:fast` or `:heavy` is unbound, it reuses the resolved `:default` provider. When `:compression` is unbound, it reuses the resolved `:fast` provider. `:default` itself has no fallback.

The four semantic roles are intentionally coarse:

- `:default` — the day-to-day model used when no specific tradeoff is required.
- `:fast` — used when latency or cost dominates.
- `:heavy` — used when reasoning depth or capacity dominates.
- `:compression` — used to summarize / compress prior context (e.g., long conversation history) into something a downstream model can consume cheaply.

The previous role-based aliases (`:thinking`, `:reasoning`, `:planning`, `:capable`) are folded into `:default`/`:heavy`. Modern (2026) LLMs all support extended thinking, so the `:thinking` distinction has no semantic content. `:image` and `:embedding` are dropped: image generation will be modeled as a function-calling skill, and the embedding use case is not currently active.

### 4.3 Alias fallback

Persisted non-default alias rows may point to either a provider or another model alias. If `:fast` or `:heavy` has no row, resolution resolves `:default` and returns that provider. If `:compression` has no row, resolution resolves `:fast` and returns that provider. If `:default` has no row, resolution returns `{:error, {:not_configured, :default}}`. Alias resolution tracks visited aliases and returns `{:error, {:alias_cycle, path}}` if database drift ever produces a cycle despite writer validation.

Fallback behavior:

| Alias | Default fallback |
| --- | --- |
| `:default` | **none — must be DB-bound to a provider** |
| `:fast` | resolved `:default` provider |
| `:heavy` | resolved `:default` provider |
| `:compression` | resolved `:fast` provider |

So with an empty DB, `resolve_alias(:compression)` falls through via `:fast` to `:default` and returns `{:error, {:not_configured, :default}}`; the bang wrapper raises. After /setup binds `:default` to a provider, every alias resolves unless the operator intentionally changes a non-default alias. If the operator binds `:fast` to a separate provider and leaves `:compression` unbound, `:compression` reuses the `:fast` provider. If the operator wants compression to reuse the normal model instead, they persist `:compression -> :default`.

### 4.4 Encrypted API key

A provider's `api_key` is stored encrypted at rest. The cipher is XChaCha20-Poly1305. The cipher key is derived from `BULLX_SECRET_BASE` per provider via `BullX.Ext.derive_key(secret_base, "llm_providers/" <> provider_id, "api_key")`. Each provider's encryption key is unique and tied to the master secret. **Master-secret rotation is not supported** — `BULLX_SECRET_BASE` is treated as immutable for the lifetime of a deployment.

Plaintext API keys appear in four places only:

1. The argument to `BullXAIAgent.LLM.Writer.put_provider/1`.
2. The transient frame inside `BullXAIAgent.LLM.Crypto.decrypt_api_key/2` during alias resolution.
3. The resolved request opts passed to `req_llm` for a single request.
4. The transient `BullXWeb.SetupLLMController` call frame when resolving `api_key_inherits_from` during `providers_save/2`: the source's plaintext is decrypted via `Crypto.decrypt_api_key/2`, substituted into the inheriting row's attrs, and immediately passed to the writer for re-encryption under the new provider's id.

They never appear in process state, in logs, in telemetry events, or in row dumps.

## 5. Data Model

### 5.1 `llm_providers`

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | `uuid` | primary key, generated via `BullX.Ecto.UUIDv7` |
| `name` | `text` | not null, unique |
| `provider_id` | `text` | not null — req_llm provider atom in string form (`"anthropic"`, `"openai"`, …) |
| `model_id` | `text` | not null — req_llm model id (`"claude-sonnet-4-20250514"`, `"kimi-k2.5"`, …) |
| `base_url` | `text` | nullable |
| `encrypted_api_key` | `text` | nullable — XChaCha20-Poly1305 ciphertext in `nonce.ciphertext` form (see §6.3) |
| `provider_options` | `jsonb` | not null, default `'{}'::jsonb` |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | not null |

`provider_id` and `model_id` are stored as text rather than as Postgres enums because the set of req_llm providers and models grows continuously upstream and operators may enter model ids that are not in the LLMDB catalog. Validation against the req_llm registry happens in `BullXAIAgent.LLM.Writer.put_provider/1` and `update_provider/2`, not in the database.

`encrypted_api_key` is nullable because some providers do not require an API key in the conventional sense (Amazon Bedrock with IAM, vLLM with no auth in development, etc.).

### 5.2 `llm_alias_bindings`

| Column | Type | Constraints |
| --- | --- | --- |
| `id` | `uuid` | primary key, generated via `BullX.Ecto.UUIDv7` |
| `alias_name` | `text` | not null, unique, `CHECK (alias_name IN ('default', 'fast', 'heavy', 'compression'))` |
| `target_kind` | `text` | not null, `CHECK (target_kind IN ('provider', 'alias'))` |
| `target_provider_id` | `uuid` | nullable, `REFERENCES llm_providers(id) ON DELETE RESTRICT`; required only when `target_kind = 'provider'` |
| `target_alias_name` | `text` | nullable, `CHECK (target_alias_name IS NULL OR target_alias_name IN ('default', 'fast', 'heavy', 'compression'))`; required only when `target_kind = 'alias'` |
| `inserted_at`, `updated_at` | `utc_datetime_usec` | not null |

`ON DELETE RESTRICT` is deliberate: deleting a provider that is still bound to an alias must be an explicit operator action. Alias-backed rows have no provider foreign key and do not block provider deletion. The writer surfaces a clear error if `delete_provider/1` is called on a referenced provider.

Table checks enforce exactly one target shape: provider targets require `target_provider_id` and a blank `target_alias_name`; alias targets require `target_alias_name` and a blank `target_provider_id`. A separate check enforces `alias_name <> 'default' OR target_kind = 'provider'`. Cross-row cycle detection stays in the writer/controller because it depends on the effective alias graph, including implicit fallbacks.

### 5.3 Migration

`priv/repo/migrations/<timestamp>_create_llm_provider_tables.exs` creates both tables in a single migration. The migration name must be generated via `mix ecto.gen.migration create_llm_provider_tables`.

```elixir
defmodule BullX.Repo.Migrations.CreateLlmProviderTables do
  use Ecto.Migration

  def change do
    create table(:llm_providers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :provider_id, :text, null: false
      add :model_id, :text, null: false
      add :base_url, :text
      add :encrypted_api_key, :text
      add :provider_options, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_providers, [:name])

    create table(:llm_alias_bindings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :alias_name, :text, null: false
      add :target_kind, :text, null: false

      add :target_provider_id,
          references(:llm_providers, type: :uuid, on_delete: :restrict),
          null: true

      add :target_alias_name, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_alias_bindings, [:alias_name])

    create constraint(:llm_alias_bindings, :alias_name_in_set,
             check: "alias_name IN ('default', 'fast', 'heavy', 'compression')"
           )

    create constraint(:llm_alias_bindings, :target_kind_in_set,
             check: "target_kind IN ('provider', 'alias')"
           )

    create constraint(:llm_alias_bindings, :target_alias_name_in_set,
             check:
               "target_alias_name IS NULL OR target_alias_name IN ('default', 'fast', 'heavy', 'compression')"
           )

    create constraint(:llm_alias_bindings, :alias_binding_target_shape,
             check:
               """
               (
                 target_kind = 'provider' AND
                 target_provider_id IS NOT NULL AND
                 target_alias_name IS NULL
               ) OR (
                 target_kind = 'alias' AND
                 target_provider_id IS NULL AND
                 target_alias_name IS NOT NULL
               )
               """
           )

    create constraint(:llm_alias_bindings, :default_alias_must_target_provider,
             check: "alias_name <> 'default' OR target_kind = 'provider'"
           )
  end
end
```

## 6. Encryption

### 6.1 NIF API

`native/bullx_ext/src/crypto/aead.rs` (new) exposes two NIFs:

```text
aead_encrypt(plaintext :: binary(), key :: String.t()) ::
  {:ok, String.t()} | {:error, String.t()}

aead_decrypt(ciphertext :: String.t(), key :: String.t()) ::
  {:ok, binary()} | {:error, String.t()}
```

- `key` is a 64-character hex string (32 bytes), matching the output of `BullX.Ext.derive_key/3` and `BullX.Ext.generate_key/0`.
- `aead_encrypt/2` generates a fresh 24-byte XChaCha20 nonce per call from the OS RNG (via `rand_chacha::ChaCha12Rng::from_os_rng`), encrypts with `XChaCha20Poly1305::encrypt`, and returns `"<base64url(nonce)>.<base64url(ciphertext)>"`.
- `aead_decrypt/2` splits on `"."`, decodes both halves from base64-url-safe, and decrypts. A malformed input returns `{:error, _}` rather than raising.

The Rust implementation mirrors the reference snippet provided in the design discussion. It runs on the dirty-CPU scheduler, like the other `bullx_ext` crypto NIFs.

`native/bullx_ext/Cargo.toml` adds:

- `chacha20poly1305 = "0.10"`

The base64-url-safe helpers are reused from `native/bullx_ext/src/encoding/base64.rs`. The `.` separator is safe because base64-url-safe never produces `.`.

The Elixir-side declarations live in `lib/bullx/ext.ex`:

```elixir
@doc """
XChaCha20-Poly1305-IETF authenticated encryption with associated data.

`key` is a 64-character hex string (32 bytes). The output is
`"<base64url(nonce)>.<base64url(ciphertext)>"` and is safe to store as
a single column. A fresh 24-byte nonce is generated per call.
"""
@spec aead_encrypt(binary(), String.t()) :: result(String.t())
def aead_encrypt(_plaintext, _key), do: :erlang.nif_error(:nif_not_loaded)

@doc """
Inverse of `aead_encrypt/2`. Returns the original plaintext as a binary.
A malformed ciphertext or wrong key yields `{:error, reason}`.
"""
@spec aead_decrypt(String.t(), String.t()) :: result(binary())
def aead_decrypt(_ciphertext, _key), do: :erlang.nif_error(:nif_not_loaded)
```

### 6.2 Per-provider key derivation

`BullXAIAgent.LLM.Crypto` is the single module that derives encryption keys. It uses `BullX.Config.Secrets.secret_base!/0` (declared in RFC 0001) as the seed and never hard-codes a key.

```elixir
defmodule BullXAIAgent.LLM.Crypto do
  @sub_key_prefix "llm_providers/"

  @spec derive_provider_key(binary()) :: {:ok, String.t()} | {:error, term()}
  def derive_provider_key(provider_id) when is_binary(provider_id) do
    case BullX.Ext.derive_key(
           BullX.Config.Secrets.secret_base!(),
           @sub_key_prefix <> provider_id,
           "api_key"
         ) do
      hex when is_binary(hex) -> {:ok, hex}
      {:error, _reason} = err -> err
    end
  end

  @spec encrypt_api_key(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def encrypt_api_key(api_key, provider_id)

  @spec decrypt_api_key(String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def decrypt_api_key(ciphertext, provider_id)
end
```

`provider_id` is the row's UUID in canonical string form. The sub-key id (`"llm_providers/<uuid>"`) is namespaced so future tables that store secrets cannot collide with the provider keyspace.

### 6.3 Storage format

`encrypted_api_key` stores the raw NIF output verbatim:

```text
<base64url(nonce)>.<base64url(ciphertext)>
```

The `.` separator is unambiguous because base64-url-safe never emits `.`. There is no schema-level header byte and no version field; the format is XChaCha20-Poly1305 by RFC fiat, and a future migration to a different cipher would be a new column.

A stored ciphertext is opaque to Postgres. Clients that bypass `BullXAIAgent.LLM.Catalog` (for example, a future web admin reading `llm_providers` directly to display masked keys) must call `BullXAIAgent.LLM.Crypto.decrypt_api_key/2` to obtain plaintext.

### 6.4 Failure modes

Master-secret rotation is unsupported (§4.4), so the runtime sees only one decryption failure mode plus one startup failure mode:

- **Corrupted ciphertext — runtime.** `aead_decrypt/2` returns `{:error, _}` (split failure, base64 decode failure, or AEAD tag mismatch). `BullXAIAgent.LLM.Catalog.resolve_alias/1` surfaces this as `{:error, {:decrypt_failed, provider_name}}` with no silent fallback (§7.4). The provider row is not deleted; the operator must re-enter the api_key.
- **Master secret missing — startup.** `BullX.Config.Secrets.secret_base!/0` already raises per RFC 0001 §7.1 / §10.2; nothing in this RFC changes that. The catalog cache cannot start; the application fails to boot.

## 7. Module Specifications

### 7.1 `BullXAIAgent.LLM.Provider`

`lib/bullx_ai_agent/llm/provider.ex` is the Ecto schema for the `llm_providers` table.

```elixir
defmodule BullXAIAgent.LLM.Provider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  schema "llm_providers" do
    field :name, :string
    field :provider_id, :string
    field :model_id, :string
    field :base_url, :string
    field :encrypted_api_key, :string
    field :provider_options, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(name provider_id model_id)a
  @optional ~w(base_url encrypted_api_key provider_options)a

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_-]{0,62}$/)
    |> validate_length(:provider_id, min: 1, max: 64)
    |> validate_length(:model_id, min: 1, max: 128)
    |> unique_constraint(:name)
  end
end
```

- The `name` regex matches operator-friendly identifiers and is intentionally narrow so a future console can use them in URLs without escaping.
- The schema does not own the cipher → plaintext translation; that lives in `BullXAIAgent.LLM.Writer` and `BullXAIAgent.LLM.Catalog`.

### 7.2 `BullXAIAgent.LLM.AliasBinding`

`lib/bullx_ai_agent/llm/alias_binding.ex` is the Ecto schema for `llm_alias_bindings`.

```elixir
defmodule BullXAIAgent.LLM.AliasBinding do
  use Ecto.Schema
  import Ecto.Changeset

  @aliases ~w(default fast heavy compression)
  @target_kinds ~w(provider alias)

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  schema "llm_alias_bindings" do
    field :alias_name, :string
    field :target_kind, :string
    field :target_provider_id, BullX.Ecto.UUIDv7
    field :target_alias_name, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:alias_name, :target_kind, :target_provider_id, :target_alias_name])
    |> validate_required([:alias_name, :target_kind])
    |> validate_inclusion(:alias_name, @aliases)
    |> validate_inclusion(:target_kind, @target_kinds)
    |> validate_inclusion(:target_alias_name, @aliases)
    |> validate_target_shape()
    |> validate_default_target()
    |> unique_constraint(:alias_name)
    |> foreign_key_constraint(:target_provider_id)
  end
end
```

The schema validates the local row shape. The writer and setup controller validate cross-row invariants: `:default` cannot target an alias and the effective alias graph cannot contain a cycle.

### 7.3 `BullXAIAgent.LLM.Crypto`

Already specified in §6.2. `decrypt_api_key/2` returns `{:ok, plaintext}` or `{:error, reason}` and never raises on bad input. `encrypt_api_key/2` returns `{:ok, ciphertext}` or `{:error, reason}` and is called only from `BullXAIAgent.LLM.Writer`.

### 7.4 `BullXAIAgent.LLM.Catalog`

`lib/bullx_ai_agent/llm/catalog.ex` is the public read API. All read paths are served from the in-memory cache owned by `BullXAIAgent.LLM.Catalog.Cache`.

`lib/bullx_ai_agent/llm/resolved_provider.ex` defines `BullXAIAgent.LLM.ResolvedProvider`, a small struct used only as the boundary object between the catalog and BullXAIAgent's req_llm calls:

```elixir
defmodule BullXAIAgent.LLM.ResolvedProvider do
  @moduledoc false

  @enforce_keys [:model, :opts]
  defstruct [:model, :opts]

  @type t :: %__MODULE__{
          model: ReqLLM.model_input(),
          opts: keyword()
        }
end
```

Required public API:

```elixir
defmodule BullXAIAgent.LLM.Catalog do
  @type alias_name :: :default | :fast | :heavy | :compression

  @spec list_providers() :: [BullXAIAgent.LLM.Provider.t()]
  def list_providers()

  @spec find_provider(String.t()) ::
          {:ok, BullXAIAgent.LLM.Provider.t()} | {:error, :not_found}
  def find_provider(name)

  @spec list_alias_bindings() :: %{alias_name() => {:provider, String.t()} | {:alias, alias_name()}}

  @spec default_alias_configured?() :: boolean()
  def default_alias_configured?()

  @spec resolve_alias(alias_name()) ::
          {:ok, BullXAIAgent.LLM.ResolvedProvider.t()}
          | {:error, {:not_configured, :default}
                     | {:alias_cycle, [alias_name()]}
                     | {:decrypt_failed, String.t()}
                     | {:unknown_provider, String.t()}}

  @spec resolve_alias!(alias_name()) :: BullXAIAgent.LLM.ResolvedProvider.t() | no_return
end
```

`list_alias_bindings/0` returns only the persisted DB rows. Callers that need a "merged effective view" — for example the setup-LLM controller (§10.4) showing each alias as either an explicit override or a synthetic fallback row — assemble that view themselves. Keeping the catalog API persistence-only avoids smuggling UI semantics into the data layer.

`default_alias_configured?/0` returns `true` only when `resolve_alias(:default)` would succeed. The /setup wizard uses it as the LLM-phase predicate.

Resolution semantics for `resolve_alias/1`:

1. Look up the alias in the cached DB binding map.
2. If the alias is bound to a provider:
   - Look up the provider record. If it is missing from the cache (referential drift), return `{:error, {:unknown_provider, name}}`.
   - If the provider has `encrypted_api_key`, decrypt it. On failure, return `{:error, {:decrypt_failed, name}}` with no silent fallback. The strict surfacing makes "rotate the master secret" vs. "configure :default" two distinguishable diagnostics.
   - Build a `BullXAIAgent.LLM.ResolvedProvider` from the row. `model` contains only req_llm model fields (`provider`, `id`, and optional `base_url`). `opts` contains DB-derived request options: `api_key` when present and `provider_options` when non-empty. `provider_options` are converted from JSON storage into the atom-keyed and schema-normalized shape req_llm expects; if this fails, return `{:error, {:invalid_provider_options, provider_name, reason}}`. Return `{:ok, resolved}`.
3. If the alias is bound to another alias, resolve the target alias with the same visited-alias set. If a cycle is detected, return `{:error, {:alias_cycle, path}}`.
4. If the alias has no DB binding:
   - For `:default`: return `{:error, {:not_configured, :default}}`. The /setup wizard's LLM phase is the only legitimate way to clear this.
   - For `:fast` and `:heavy`: resolve `:default` and return that provider or its error.
   - For `:compression`: resolve `:fast` and return that provider or its error.

`resolve_alias!/1` raises a descriptive error on `{:error, _}`. `BullXAIAgent.ModelAliases.resolve_model/1` calls `resolve_alias!/1` and returns the resolved provider struct.

### 7.5 `BullXAIAgent.LLM.Catalog.Cache`

`lib/bullx_ai_agent/llm/catalog/cache.ex` is the GenServer that owns the cache state. Its parent is `BullXAIAgent.Supervisor` (§7.13); its failure boundary is the AIAgent supervision tree.

Responsibilities:

- On `init/1`, load all `llm_providers` and `llm_alias_bindings` rows into two ETS tables.
- Expose read accessors used by `BullXAIAgent.LLM.Catalog`.
- Expose `refresh_provider/1`, `refresh_alias/1`, `refresh_all/0` invoked by `BullXAIAgent.LLM.Writer` after every successful write.

Required behavior:

- ETS table names: `:bullx_llm_providers`, `:bullx_llm_alias_bindings`.
- ETS options: `[:named_table, :protected, read_concurrency: true]`.
- `refresh_*/1` and `refresh_all/0` are `GenServer.call/2` so callers can rely on the refresh having completed before the call returns.
- Read accessors must wrap `:ets.lookup` in `try/rescue ArgumentError` so a transient missing table (during a Cache crash-restart) returns `:error` rather than crashing the caller.
- If the database query in `init/1` fails — for example because `mix ecto.migrate` has not yet been run — log a warning and start with empty tables. Alias resolution then falls through to `:default` behavior.
- The cache uses its own database connection; tests must allow it via `Ecto.Adapters.SQL.Sandbox.allow/3`, mirroring RFC 0001 §9.2's pattern.

### 7.6 `BullXAIAgent.LLM.Writer`

`lib/bullx_ai_agent/llm/writer.ex` is the only supported write path. It encapsulates encryption on input, validation, and cache refresh on output.

Required public API:

```elixir
defmodule BullXAIAgent.LLM.Writer do
  @type provider_attrs :: %{
          required(:name) => String.t(),
          required(:provider_id) => String.t(),
          required(:model_id) => String.t(),
          optional(:base_url) => String.t(),
          optional(:api_key) => String.t() | nil,
          optional(:provider_options) => map()
        }

  @spec put_provider(provider_attrs()) ::
          {:ok, BullXAIAgent.LLM.Provider.t()} | {:error, Ecto.Changeset.t() | term()}

  @spec update_provider(BullXAIAgent.LLM.Provider.t(), provider_attrs()) ::
          {:ok, BullXAIAgent.LLM.Provider.t()} | {:error, Ecto.Changeset.t() | term()}

  @spec delete_provider(String.t()) :: :ok | {:error, term()}

  @spec put_alias_binding(
          BullXAIAgent.LLM.Catalog.alias_name(),
          {:provider, String.t()} | {:alias, BullXAIAgent.LLM.Catalog.alias_name()}
        ) :: {:ok, BullXAIAgent.LLM.AliasBinding.t()} | {:error, term()}

  @spec delete_alias_binding(BullXAIAgent.LLM.Catalog.alias_name()) :: :ok | {:error, term()}
end
```

Required behavior:

- `put_provider/1`:
  1. Generate the row's UUID via `BullX.Ecto.UUIDv7` so the encryption key derivation has a stable id before insertion.
  2. If `:api_key` is present and non-empty, derive the per-provider key and encrypt; persist the ciphertext in `encrypted_api_key`.
  3. If `:api_key` is `nil` or omitted, set `encrypted_api_key` to `nil`.
  4. Validate and normalize `:provider_options` through `BullXAIAgent.LLM.ProviderOptions` against the selected req_llm provider's `provider_schema/0`. Unknown keys or invalid values return `{:error, {:invalid_provider_options, reason}}`; JSON-safe normalized values are stored in `llm_providers.provider_options`.
  5. Insert in a transaction. On success, refresh the cache for that provider.
- `update_provider/2`:
  1. Re-derive the key from the existing UUID.
  2. If `:api_key` is present in the attrs map, re-encrypt; if absent, leave `encrypted_api_key` untouched. Pass `:api_key => nil` explicitly to clear it.
  3. Validate and normalize `:provider_options` the same way as `put_provider/1`.
  4. Update in a transaction; refresh the cache.
- `delete_provider/1`:
  1. Resolve by `name`. If it does not exist, return `{:error, :not_found}`.
  2. Attempt delete. If a `target_provider_id` reference still exists in `llm_alias_bindings`, the foreign key fires and the writer surfaces `{:error, {:still_referenced_by_alias, alias_name}}`.
  3. On success, refresh the cache.
- `put_alias_binding/2`:
  1. Accept `{:provider, provider_name}` for every alias and `{:alias, target_alias}` for non-default aliases.
  2. Reject `:default` alias targets with `{:error, {:default_alias_must_target_provider, :default}}`.
  3. If the named provider does not exist, return `{:error, {:unknown_provider, name}}`; if the target alias is unknown, return `{:error, {:unknown_alias, value}}`.
  4. Validate the effective alias graph, including implicit fallbacks, and reject cycles with `{:error, {:alias_cycle, path}}`.
  5. Upsert in a transaction; refresh the cache.
- `delete_alias_binding/1` is idempotent for unknown aliases and absent rows, but it validates that deleting an existing row would not create a cycle through implicit fallbacks. On success it removes the row if present and refreshes the cache.

The writer never logs or returns plaintext API keys.

### 7.7 `BullXAIAgent.ModelAliases`

`lib/bullx_ai_agent/model_aliases.ex` is rewritten in full.

```elixir
defmodule BullXAIAgent.ModelAliases do
  @moduledoc """
  Four-alias model resolution backed by the LLM provider catalog.

  Allowed aliases are statically `:default`, `:fast`, `:heavy`, `:compression`.
  Mappings are operator-managed via `BullXAIAgent.LLM.Writer`. Persisted
  bindings always target providers. When `:fast` or `:heavy` has no row, it
  reuses the resolved `:default` provider. When `:compression` has no row, it
  reuses the resolved `:fast` provider. `:default` has no fallback.
  """

  @type alias_name :: :default | :fast | :heavy | :compression

  @spec aliases() :: [alias_name()]
  def aliases, do: [:default, :fast, :heavy, :compression]

  @spec alias?(term()) :: boolean()
  def alias?(value), do: value in [:default, :fast, :heavy, :compression]

  @spec resolve_model(alias_name()) :: BullXAIAgent.LLM.ResolvedProvider.t() | no_return
  def resolve_model(alias_name)
      when alias_name in [:default, :fast, :heavy, :compression] do
    BullXAIAgent.LLM.Catalog.resolve_alias!(alias_name)
  end

  def resolve_model(other) do
    raise ArgumentError,
          "Unknown model alias: #{inspect(other)}. " <>
            "Allowed aliases are :default, :fast, :heavy, :compression."
  end
end
```

Notes:

- Non-default aliases may form persisted alias chains, but cycles are invalid. The implicit fallback remains code-level: unbound `:fast` and `:heavy` reuse the resolved `:default` provider, and unbound `:compression` reuses the resolved `:fast` provider.
- The previous `model_aliases/0` map function is removed. There is no merged map of overrides; the catalog is the source of truth.
- `BullXAIAgent.resolve_model/1` (in `lib/bullx_ai_agent.ex`) dispatches atom inputs to `ModelAliases.resolve_model/1`. Normal call sites do not pass direct req_llm model specs; setup-time provider validation may pass a transient `ResolvedProvider`.

### 7.8 `BullX.Config.ReqLLM`

`lib/bullx/config/req_llm.ex` declares the `req_llm` settings that go through the bridge.

```elixir
defmodule BullX.Config.ReqLLM do
  use BullX.Config

  @envdoc false
  bullx_env(:receive_timeout_ms,
    key: [:req_llm, :receive_timeout],
    type: :integer,
    default: 30_000
  )

  @envdoc false
  bullx_env(:metadata_timeout_ms,
    key: [:req_llm, :metadata_timeout],
    type: :integer,
    default: 300_000
  )

  @envdoc false
  bullx_env(:stream_completion_cleanup_after_ms,
    key: [:req_llm, :stream_completion_cleanup_after],
    type: :integer,
    default: 30_000
  )

  @envdoc false
  bullx_env(:debug,
    key: [:req_llm, :debug],
    type: :boolean,
    default: false
  )

  @envdoc false
  bullx_env(:redact_context,
    key: [:req_llm, :redact_context],
    type: :boolean,
    default: false
  )

  @doc false
  def bridge_keyspec do
    [
      {:receive_timeout, &receive_timeout_ms!/0},
      {:metadata_timeout, &metadata_timeout_ms!/0},
      {:stream_completion_cleanup_after, &stream_completion_cleanup_after_ms!/0},
      {:debug, &debug!/0},
      {:redact_context, &redact_context!/0}
    ]
  end
end
```

The set is intentionally limited to settings that req_llm reads on every call (or per-stream). Settings that req_llm reads once during its own application start (`:custom_providers`, `:load_dotenv`) are out of scope per §2.2 — they remain in compile-time `config/*.exs` and can be overridden only by editing those files and restarting.

Provider-specific keys (`:anthropic_api_key`, `:azure_api_key`, `:azure`, …) are also out of scope. They are subsumed by `llm_providers` rows; we never bridge them.

### 7.9 `BullX.Config.ReqLLM.Bridge`

`lib/bullx/config/req_llm/bridge.ex` is a plain module (not a GenServer) that pushes resolved values into `Application.put_env(:req_llm, …)` so unmodified `req_llm` reads them through its existing `Application.get_env/2` calls. It owns no state; `Application` is the state owner.

Required public API:

```elixir
defmodule BullX.Config.ReqLLM.Bridge do
  @spec sync_all!() :: :ok
  def sync_all! do
    Enum.each(BullX.Config.ReqLLM.bridge_keyspec(), fn {key, fun} ->
      Application.put_env(:req_llm, key, fun.())
    end)
    :ok
  end

  @spec sync_key!(String.t()) :: :ok
  def sync_key!(_bullx_key), do: sync_all!()
end
```

`lib/bullx/config/req_llm/boot_sync.ex` is the synchronous one-shot child used only to preserve startup ordering:

```elixir
defmodule BullX.Config.ReqLLM.BootSync do
  @moduledoc false

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(_opts) do
    BullX.Config.ReqLLM.Bridge.sync_all!()
    :ignore
  end
end
```

Invocation:

- **Boot.** `BullX.Config.Supervisor` lists `BullX.Config.ReqLLM.BootSync` immediately after `BullX.Config.Cache`. OTP starts children in order, so the cache is available before `BootSync.start_link/1` runs. `BootSync.start_link/1` calls `Bridge.sync_all!/0` synchronously and returns `:ignore`; therefore the sync completes before `BullX.Config.Supervisor.start_link/1` returns and before later top-level subsystem supervisors start. There is no long-lived bridge process.
- **Runtime updates.** `BullX.Config.Writer.put/2` and `BullX.Config.Writer.delete/1` inspect the written key; if it starts with `bullx.req_llm.`, they call `BullX.Config.ReqLLM.Bridge.sync_key!/1` synchronously. This is a function call, not a message, so completion is immediate.

The bridge intentionally pushes the full keyspec on every sync rather than tracking which keys changed. The keyspec is a list of five lookups; the cost is negligible. A finer-grained sync is a future optimization that this RFC does not adopt.

The bridge does not push `:custom_providers`, `:load_dotenv`, provider-specific API keys (`:anthropic_api_key`, `:azure_api_key`, …), or `:finch_request_adapter`:

- `:load_dotenv` is hard-coded `false` in `config/config.exs`.
- `:custom_providers` is registered in code via `BullXAIAgent.LLM.register_custom_providers/0` (§7.14).
- Provider-specific API keys are subsumed by the `llm_providers` table; the catalog places decrypted keys in the resolved provider's request opts for the single req_llm call.
- `:finch_request_adapter` is a test-only override; tests continue to use `Application.put_env/3` directly.

### 7.10 `BullXAIAgent.Plugins.ModelRouting`

`lib/bullx_ai_agent/plugins/model_routing.ex` is updated in two places:

1. `@default_routes` is rewritten in terms of the four new aliases. The mapping reflects the coarser semantic split:

```elixir
@default_routes %{
  "chat.message" => :default,
  "chat.simple" => :fast,
  "chat.complete" => :fast,
  "chat.generate_object" => :default,
  "chat.compress" => :compression,
  "reasoning.*.run" => :heavy
}
```

2. The doctring example referencing `:capable`, `:thinking`, `:reasoning`, `:embedding` is updated to use the new aliases.

The plugin's wildcard matching, signal-data override behavior, and schema are unchanged.

`BullXAIAgent.Plugins.Chat` drops the inactive `chat.embed` route and its
`BullXAIAgent.Actions.LLM.Embed` action. The embedding directive and
`ai.embed.result` signal are deleted with it because they would otherwise keep a
direct non-catalog `ReqLLM.Embedding.embed/3` path alive.

### 7.11 `BullXAIAgent`

`lib/bullx_ai_agent.ex` changes:

- Replace the per-kind `@default_llm_defaults` map with a single set of numeric module attributes:

  ```elixir
  @llm_default_temperature 0.2
  @llm_default_max_tokens 1024
  @llm_default_timeout_ms 30_000
  ```

  `llm_defaults/0` and `llm_defaults/1` are rewritten to return `%{model: :default, temperature: @llm_default_temperature, max_tokens: @llm_default_max_tokens, timeout: @llm_default_timeout_ms}` for every kind. The per-kind branching disappears; the function arity stays for source-compatibility with internal call sites.
- Remove `config/2` outright. After the Standalone Runtime cleanup (§7.12) it has zero call sites.
- Update `@type model_alias` to `:default | :fast | :heavy | :compression`.
- Narrow BullXAIAgent model inputs to aliases for normal call sites. Direct req_llm inline model specs are not a BullXAIAgent provider-configuration path in this RFC; the only direct `ResolvedProvider` input is the setup controller's transient provider check before the submitted row is saved.
- Update the generation facades (`generate_text/2`, `generate_object/3`, and helper call paths) so alias resolution returns a `BullXAIAgent.LLM.ResolvedProvider`; the facades also accept a `ResolvedProvider` directly for setup-time provider checks. After rejecting provider config keys from call-level opts, the facade calls req_llm with `resolved.model` and `Keyword.merge(generation_opts, resolved.opts)` immediately before the call. Provider config is not overridable from call-level opts: callers may pass generation controls, but `:api_key`, `:base_url`, and `:provider_options` are rejected with `{:error, {:provider_config_must_use_catalog, key}}`.
- Update the `## Model Aliases` and `## LLM Defaults` sections of the moduledoc to reflect the new system. Drop the `:image`, `:embedding`, `:capable`, `:thinking`, `:reasoning`, and `:planning` examples.

### 7.12 Standalone Runtime removal

`BullXAIAgent.Reasoning.AgenticLoop` carries a forked-from-jido_ai feature for resuming an in-flight loop across stateless calls via signed checkpoint tokens. BullX has no use case for it. The full removal:

**Module deleted:**

- `lib/bullx_ai_agent/reasoning/agentic_loop/token.ex` — entire `BullXAIAgent.Reasoning.AgenticLoop.Token` module (`issue/2`, `decode/2`, the cancel-token helper, and any private helpers).

**`BullXAIAgent.Reasoning.AgenticLoop.Config` (`agentic_loop/config.ex`):**

- Remove `@legacy_insecure_token_secret`, `@ephemeral_secret_key`, `@ephemeral_secret_warned_key`.
- Remove the `token_secret` field from the resolved config struct and its load logic (the `BullXAIAgent.config(:agentic_loop_token_secret, …)` lookup).
- Remove `normalize_token_secret/1`, `ephemeral_token_secret/0`, and the warning / error messages they emit.
- Remove `config_fingerprint/1` if it has no remaining caller after token removal. Audit the call graph first; if anything outside the token path still uses it, leave it alone.

**`BullXAIAgent.Reasoning.AgenticLoop.Runner` (`agentic_loop/runner.ex`):**

- Remove `emit_checkpoint/5` and the `Token` alias.
- Delete every call site that invokes `emit_checkpoint(...)` — the cancellation path, the failure path, after-LLM, after-tools, and terminal phases. The states they were applied to remain; only the `:checkpoint` event emission is removed.
- If observability of after-LLM / after-tools intermediate state is later wanted, add proper `:telemetry.execute/3` events. This RFC does not.

**`BullXAIAgent.Reasoning.AgenticLoop.Strategy` (`agentic_loop/strategy.ex`):**

- Remove the `:checkpoint_token` field everywhere it appears in the per-request state map.
- Remove the `:checkpoint` runtime-kind branch and the `runtime_kind_from_string("checkpoint")` clause.

**`BullXAIAgent.Reasoning.AgenticLoop.Actions.*`:**

- Remove the `:token_secret` parameter from `Start`, `Cancel`, `Continue`, `Collect` schemas.
- In `Collect`: remove the `params[:checkpoint_token]` decode branch; the action now requires `:events` and returns `{:error, :events_required}` when absent.

**`BullXAIAgent.Reasoning.AgenticLoop.Actions.Helpers`:**

- Remove the `token_secret: params[:token_secret] || context[:agentic_loop_token_secret]` fallback line.

**Net effect:**

- One module deleted, ~80 lines removed across config / runner / strategy / actions.
- The agentic loop runs purely as a process-resident state machine. Cancellation, after-LLM, after-tools, and terminal phases continue to drive state transitions; they just stop emitting checkpoint-bearing events.
- The only `BullXAIAgent.config/2` call site disappears, so `BullXAIAgent.config/2` itself can be deleted with no migration target.

### 7.13 `BullXAIAgent.Supervisor`

`lib/bullx_ai_agent/supervisor.ex` is the new top-level AIAgent supervisor.

```elixir
defmodule BullXAIAgent.Supervisor do
  @moduledoc """
  Top-level supervisor for AIAgent runtime workers.

  Owns the LLM provider catalog cache today; will own additional AIAgent
  workers (sub-agent pools, observation taps, request lifecycle services) as
  they are introduced by future RFCs.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    BullXAIAgent.LLM.register_custom_providers()

    children = [
      BullXAIAgent.LLM.Catalog.Cache
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Notes:

- Strategy is `:one_for_one`. New AIAgent workers are independent and should not cascade restarts.
- `register_custom_providers/0` is invoked once during `init/1`, before any catalog work, so a custom `ReqLLM.Provider` module is available before resolution starts. Re-running the supervisor (for example through a `Supervisor.restart_child/2` cascade) re-registers idempotently because `ReqLLM.Providers.register/1` overwrites by id.
- This module supersedes RFC 0000 §5.1's "AIAgent has no supervisor" rule for AIAgent specifically. RFC 0000 §5.1 remains in force for any other namespace it describes.

### 7.14 `BullXAIAgent.LLM`

`lib/bullx_ai_agent/llm.ex` is a thin module that exposes the in-code custom-provider registration hook and is the natural import target for future LLM-side helpers.

```elixir
defmodule BullXAIAgent.LLM do
  @moduledoc """
  Public LLM-side surface for BullXAIAgent.

  ## Custom `ReqLLM.Provider` registration

  `BullXAIAgent.Supervisor.init/1` invokes `register_custom_providers/0` once
  at boot. To add a custom provider implementation, edit this function and
  add a `ReqLLM.Providers.register!/1` call. Provider modules are intentionally
  registered in code rather than through `BullX.Config` because they are code
  artifacts and the underlying req_llm registry is keyed by module atoms read
  once at application start.
  """

  @doc """
  Registers BullX-internal custom `ReqLLM.Provider` modules.
  """
  @spec register_custom_providers() :: :ok
  def register_custom_providers do
    ReqLLM.Providers.register!(BullXAIAgent.LLM.Providers.VolcengineArk)
    ReqLLM.Providers.register!(BullXAIAgent.LLM.Providers.XiaomiMiMo)

    :ok
  end
end
```

Notes:

- The function is intentionally a single, edit-when-needed body. There is no DSL, no list of modules, and no compile-time accumulation. The simplicity is the design.
- Removing a previously registered custom provider requires a code edit plus a node restart. There is no `unregister_custom_providers/0`; callers may call `ReqLLM.Providers.unregister/1` directly if they really need to.

### 7.15 `config/config.exs`

`config/config.exs` is modified to add a single line that disables req_llm's built-in dotenv loader:

```elixir
config :req_llm, load_dotenv: false
```

Rationale: BullX has its own dotenv pipeline (RFC 0001 §3.7) that runs before req_llm's `Application.start/2` would have a chance to load anything useful in our deployment topology. Letting both run is a pure source of confusion. There is no operator knob to flip it back on; adding one would require re-introducing a setting that is intentionally out of scope.

## 8. Application Tree

Two changes to the supervision tree:

1. `BullX.Config.Supervisor` gains `BullX.Config.ReqLLM.BootSync` immediately after `BullX.Config.Cache`. `BootSync.start_link/1` runs the req_llm sync synchronously and returns `:ignore`. This preserves the required startup guarantee: the sync runs after `BullX.Config.Cache` is available and before `BullX.Config.Supervisor.start_link/1` returns.

```elixir
# lib/bullx/config/supervisor.ex
children = [
  BullX.Config.Cache,
  BullX.Config.ReqLLM.BootSync
]
```

2. `BullX.Application.start/2` adds `BullXAIAgent.Supervisor` as a top-level child. It must start after `BullX.Config.Supervisor` (so `BullX.Config.Secrets.secret_base!/0` and the bridge are available) and before any subsystem supervisor that may resolve aliases or construct AIAgent agents on boot.

```elixir
# lib/bullx/application.ex
# Preserve all existing top-level children; this excerpt only shows the required
# relative placement for BullXAIAgent.Supervisor.
children = [
  BullXWeb.Telemetry,
  BullX.Repo,
  BullX.Config.Supervisor,
  {DNSCluster, query: Application.get_env(:bullx, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: BullX.PubSub},
  BullXAIAgent.Supervisor,
  BullX.Skills.Supervisor,
  BullXBrain.Supervisor,
  BullX.Runtime.Supervisor,
  BullXGateway.CoreSupervisor,
  BullXWeb.Endpoint
]
```

The placement is deliberate:

- The boot-time bridge sync runs as a synchronous one-shot start callback under `BullX.Config.Supervisor` because the bridge is config infrastructure, not AIAgent runtime. There is no long-lived bridge process.
- `BullXAIAgent.Supervisor` sits between the `BullX.Config.Supervisor` / `Phoenix.PubSub` foundation and the subsystem supervisors (`BullX.Skills`, `BullXBrain`, `BullX.Runtime`, `BullXGateway`) because all four of those may construct AIAgent agents on boot and resolve aliases through the catalog cache.
- The catalog cache's failure boundary is `BullXAIAgent.Supervisor`, not `BullX.Application`. A cache crash restarts only the cache; subsystem supervisors are unaffected.

## 9. ReqLLM Application-Start Settings

`req_llm` boots before `:bullx` because `:bullx` depends on `:req_llm`. Two `req_llm` settings are read once during `req_llm`'s own application start. Neither is bridged through `BullX.Config`:

### 9.1 `:load_dotenv`

Hard-coded to `false` for every environment. The line lives in `config/config.exs` so it is set before any `:req_llm` start path runs:

```elixir
config :req_llm, load_dotenv: false
```

Rationale: BullX owns dotenv loading through `BullX.Config.Bootstrap.load_dotenv!/1` (RFC 0001 §3.7). Letting req_llm load `.env` files independently would create a second, racing source of `System.put_env/2` calls. There is no DB override and no `bullx_env` declaration for this setting.

### 9.2 `:custom_providers`

Registered through Elixir code via `BullXAIAgent.LLM.register_custom_providers/0` (§7.14), not through `Application.put_env(:req_llm, :custom_providers, …)`.

The function is invoked from `BullXAIAgent.Supervisor.init/1` and calls `ReqLLM.Providers.register!/1` for each module. Because `ReqLLM.Providers.register/1` is idempotent (it overwrites by provider id in `:persistent_term`), this works correctly even though `:bullx` starts after `:req_llm` has already finished its own `Providers.initialize/0`.

This RFC registers two BullX-owned custom providers:

- `BullXAIAgent.LLM.Providers.VolcengineArk` — OpenAI-compatible, id `:volcengine_ark`, display labels `Volcengine Ark` / `火山方舟`, default base URL `https://ark.cn-beijing.volces.com/api/v3`, and default env key `ARK_API_KEY`.
- `BullXAIAgent.LLM.Providers.XiaomiMiMo` — Anthropic-compatible, id `:xiaomi_mimo`, display labels `Xiaomi MiMo` / `小米MiMo`, default base URL `https://api.xiaomimimo.com/anthropic`, and default env key `XIAOMI_MIMO_API_KEY`. Xiaomi's public endpoint is `https://api.xiaomimimo.com/anthropic/v1/messages`; the registered base URL intentionally excludes `/v1/messages` because req_llm's Anthropic provider appends that path.

Adding another custom provider in the future is another direct code edit, not a configuration change. There is no DSL, no module attribute list, and no build-time aggregation.

`:custom_providers` may still be set in `config/*.exs` if some external tooling needs it, but BullX itself does not write to that key.

## 10. Setup Integration

### 10.1 Phase model

The first-time setup wizard now has four ordered phases. Each phase has a predicate that determines whether it is complete:

| Phase | Predicate (true ⇒ complete) | Owner |
| --- | --- | --- |
| 1. Bootstrap activation | bootstrap activation code session is valid (`BullXAccounts.bootstrap_activation_code_valid_for_hash?/1`) | `BullXWeb.SetupSessionController` (existing) |
| 2. LLM model endpoints | `BullXAIAgent.LLM.Catalog.default_alias_configured?/0` returns `true` | `BullXWeb.SetupLLMController` (new) |
| 3. Gateway adapters | At least one enabled adapter persisted in `BullX.Config` | `BullXWeb.SetupGatewayController` (existing, lightly modified) |
| 4. Owner activation | `not BullXAccounts.setup_required?/0` | Bot `/preauth` flow + `BullXWeb.SetupController.activate_owner` SPA at `setup/ActivateOwner` |

Phase 2 is the new addition. It must be complete before phase 3 because the gateway connectivity check may eventually exercise the inbound LLM path; even today, having `:default` bound is a precondition for any subsystem that constructs an AIAgent on boot.

### 10.2 Routing

```text
GET  /setup                          — phase-aware redirector (BullXWeb.SetupController)
GET  /setup/sessions/new             — bootstrap activation entry (existing)
POST /setup/sessions                  — bootstrap session create (existing)
GET  /setup/llm                      — LLM model endpoint configuration page (new)
POST /setup/llm/providers/check      — endpoint connectivity check (new)
POST /setup/llm/providers            — endpoints + model alias bindings save (new)
GET  /setup/gateway                  — gateway adapter configuration page (was /setup)
POST /setup/gateway/adapters/check   — adapter connectivity check (existing path; controller unchanged)
POST /setup/gateway/adapters         — adapter save (existing path; controller unchanged)
GET  /setup/activate-owner           — owner activation instructions SPA (`setup/ActivateOwner`)
GET  /setup/activate-owner/status    — JSON poll for owner activation completion
```

Note the path move: the gateway page that today lives at `/setup` moves to `/setup/gateway`. The bare `/setup` becomes the redirector. Existing bookmarks to `/setup` continue to land in the right place because the redirector forwards them.

### 10.3 `BullXWeb.SetupController` (modified)

`SetupController.show/2` becomes a redirector. The decision tree:

1. If `not BullXAccounts.setup_required?()` → redirect to `/`.
2. If the bootstrap session is invalid → redirect to `/setup/sessions/new` (drop session).
3. If `not BullXAIAgent.LLM.Catalog.default_alias_configured?()` → redirect to `/setup/llm`.
4. If no enabled gateway adapter is configured → redirect to `/setup/gateway`.
5. Else → redirect to `/setup/activate-owner`.

`SetupController.show/2` is a pure redirector. `SetupController.activate_owner/2` renders a small Inertia SPA (`setup/ActivateOwner`) with the same `SetupLayout` shell as the other setup pages: a translated heading, the literal `/preauth <activation-code>` command in a mono block, and the explanation that the bootstrap code's plaintext cannot be re-displayed because only its hash is in the session. The controller passes `app_name`, the `command` string, `back_path`, and `status_path` as Inertia props; all surrounding copy is i18n-resolved client-side under `web.setup.activate_owner.*`. The page polls `status_path` every five seconds and navigates to the response's `redirect_to` once activation completes — see `activation_status/2` below. The previous gateway render path (`render_inertia(conn, "setup/App")`) is moved to `SetupGatewayController.show/2`.

`SetupController.activation_status/2` answers `GET /setup/activate-owner/status` for the SPA's poll. It returns `{"activated": false}` while `BullXAccounts.setup_required?/0` is `true`, and `{"activated": true, "redirect_to": "/"}` once it flips to `false` (owner created via the bot's `/preauth` flow). On the activated transition the action also `delete_session(:bootstrap_activation_code_hash)` so the now-stale bootstrap hash is removed from the cookie. The endpoint intentionally does not gate on `authenticated_for_setup?/1`: it only exposes a boolean already implied by the public `/setup` redirector, and dropping the session check keeps the poll cheap and survives the transient state where the consumed activation code has invalidated the session hash. The browser-side polling stops on first `activated: true` via `clearInterval`.

### 10.4 `BullXWeb.SetupLLMController` (new)

`lib/bullx_web/controllers/setup_llm_controller.ex` mirrors the structure of `SetupGatewayController`:

```elixir
defmodule BullXWeb.SetupLLMController do
  use BullXWeb, :controller

  alias BullXAIAgent.LLM.{Catalog, Crypto, Writer}

  @session_key :bootstrap_activation_code_hash

  def show(conn, _params)
  def providers_check(conn, %{"provider" => attrs})
  def providers_save(conn, %{"providers" => providers, "alias_bindings" => bindings})
end
```

Behavior:

- `show/2`:
  - Gates on `BullXAccounts.setup_required?/0` and the bootstrap session, mirroring the existing controllers.
  - Renders `setup-llm/App` with assigns:
    - `:provider_id_catalog` — one entry per `ReqLLM.Providers.list/0` provider, shaped as `%{"id" => provider_id, "label" => label, "default_base_url" => url_or_nil, "api_key_supported" => boolean, "provider_options" => fields}`. `provider_options` is derived from the provider module's `provider_schema/0` and contains JSON-safe field metadata (`key`, `label`, `input_type`, `type`, `options`, `required`, `default`, `doc`) so the UI can render advanced settings without a free-form options surface. The schema-level `:api_key` field is excluded from `provider_options` because BullX stores conventional inline API keys through `encrypted_api_key`, not plaintext provider options.
    - `:providers` — current `Catalog.list_providers/0` results, with `encrypted_api_key` redacted to `null` and a `secret_status` field set to `"stored"` when present, `"missing"` otherwise. Same redaction pattern as the gateway controller's `secret_status`.
    - `:alias_bindings` — a controller-built effective view: start from `Catalog.list_alias_bindings/0`, add synthetic fallback entries for unbound non-`:default` model aliases (`:fast`/`:heavy` reuse the `:default` model; `:compression` reuses the `:fast` model), and mark each row as either `"operator_override"` or `"fallback_provider"` so the UI can distinguish them.
    - `:check_path` — `~p"/setup/llm/providers/check"`.
    - `:save_path` — `~p"/setup/llm/providers"`.
- `providers_check/2`:
  - Validates the inbound provider attrs.
  - Builds a transient `BullXAIAgent.LLM.ResolvedProvider` from the submitted attrs using the same model/opts split as catalog resolution, then calls `BullXAIAgent.generate_text/2` with prompt `"ping"` and `max_tokens: 8`. This is setup-time validation of the operator's submitted provider row, not a code-level provider configuration path.
  - Returns `{ok: true, result: %{text: <response_text>}}` on success.
  - Returns `{ok: false, errors: [...]}` on validation or LLM failure.
  - **No connectivity token is issued.** Setup-time LLM verification is advisory; the operator is the same person who will see the failure on the first real call. Skipping tokens keeps the surface small.
- `providers_save/2`:
  - Validates the full payload before any write: LLM model endpoint rows are either complete (`provider_id`, `model_id`, optional `name`, optional `base_url`, optional `api_key`, optional `api_key_inherits_from`, optional schema-declared `provider_options`) or absent. When `name` is blank, the controller fills it as `provider_id <> "/" <> model_id` before validation and persistence. An incomplete endpoint row returns `{ok: false, errors: [...]}` and persists nothing. `provider_options` is checked against the selected req_llm provider's `provider_schema/0`; schema-unknown options are rejected instead of being stored as inert JSON.
  - Validates that exactly one binding for the `:default` model alias is present in the payload, that its `kind` is `"provider"`, and that the named endpoint is also in the payload.
  - Validates non-default alias targets and rejects alias cycles before any write. The cycle check includes implicit fallbacks (`:fast`/`:heavy -> :default`, `:compression -> :fast`) so `:fast -> :compression` is invalid unless `:compression` is explicitly rebound away from `:fast` in the same final graph.
  - Resolves `api_key_inherits_from` after normalization and before write: when a row carries `api_key_inherits_from: <source name>` and no explicit `api_key`, the controller substitutes the source's plaintext into the row's `:api_key` (preferring an in-batch source's freshly typed `:api_key`, otherwise looking up the saved provider in `Catalog.find_provider/1` and decrypting via `Crypto.decrypt_api_key/2`) and drops `:api_key_inherits_from` before passing to the writer. Explicit `api_key` (including explicit `nil` to clear) overrides the inherit. An unknown source returns `{ok: false, errors: [...]}` with field `api_key_inherits_from` and persists nothing. Re-encryption uses the new provider's UUID, so two providers that share an inherited plaintext have distinct ciphertexts. The inherited plaintext appears only in the controller call frame; it is never persisted alongside `api_key_inherits_from`.
  - Writes providers first by `name`: existing rows call `Writer.update_provider/2`, new rows call `Writer.put_provider/1`. Omitted `api_key` on an existing provider preserves the stored key; explicit `api_key: nil` clears it. Each writer call has its own transaction and cache refresh. Then the controller writes alias bindings via `Writer.put_alias_binding/2`, ordering provider targets before alias targets to avoid transient cycles while applying a prevalidated final graph.
  - The save is *not* one global transaction — that would race with the writer's cache-refresh side effects. If a write fails partway through after prevalidation, the response surfaces the error and the operator re-submits to fix; partial state from earlier successful writes is observable through the catalog.
  - Alias-to-alias bindings are allowed for non-default aliases when acyclic. `:default` alias targets and all alias cycles are rejected before persistence.
  - On success, returns `{ok: true, redirect_to: "/setup/gateway"}`.

### 10.5 `BullXWeb.SetupGatewayController` (modified)

`SetupGatewayController` owns GET `/setup/gateway` and renders the existing gateway-channel setup SPA at `setup/App`. The route, payload shapes, and connectivity-token machinery remain unchanged. Save still redirects to `/setup/activate-owner` on success — the LLM phase is upstream of gateway, so `/setup/activate-owner` is the natural next stop.

### 10.6 LLM setup SPA (`webui/src/apps/setup-llm/App.jsx`)

Page structure mirrors the gateway page's idioms. Two sections on a single card:

1. **LLM model endpoints section.** A list of endpoint rows with add / edit / delete / "Test" actions. Each row shows `name`, vendor (`provider_id`), `model_id`, base_url status, and api_key secret status (`stored` badge vs empty) only for providers that support a conventional inline API key. The add flow uses the same select-then-configure `Sheet` pattern as gateway channel setup: first choose how to start, then configure the endpoint. The select step shows a default-collapsed "Copy configuration from a saved endpoint" panel above the vendor tiles when at least one previously saved endpoint already has a stored API key (`secret_status.api_key === "stored"` and a server-assigned `id`); expanding it lists those endpoints as cards. Picking a saved endpoint there prefills the configure view with that endpoint's `provider_id`, `model_id`, `base_url`, and `provider_options`, leaves `name` blank for the operator to fill, and stamps `api_key_inherits_from: <source name>` on the draft. The configure view collects:
   - `name` — optional operator-friendly identifier. The placeholder is `provider_id/model_id`; blank saves as that value. The effective value is regex-validated client-side and server-side: `^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,192}$`. When the prepared `name` would collide with another row's prepared `name` in the current list, the configure view shows a live duplicate-name error on the field, switches the field to required, and clears the placeholder so the operator must enter a unique name before "Add"/"Save changes" succeeds. Names are still validated server-side; the live UI check is a redundant friendly path.
   - `provider_id` — vendor `Select` populated from `provider_id_catalog`. Display labels are translated through `web.setup.llm.provider_catalog.<provider_id>` and fall back to the provider key with its first letter capitalized when no translation exists.
   - `model_id` — text input (free-form; req_llm catalog lookup happens server-side).
   - `api_key` — password input rendered only when the selected req_llm provider declares a conventional inline API-key path: either its default env key is API-key-like or its provider schema contains `:api_key`. It is always re-enterable on edit; the row shows a "stored" badge when an encrypted key exists. When the draft carries `api_key_inherits_from` and the operator has not typed a fresh value, the field shows an inline "API key inherited from {source}" hint; typing any value implicitly overrides the inherit at save time. Switching the vendor (`provider_id`) clears `api_key_inherits_from` because an inherited key is vendor-specific.
   - **Advanced settings** — a collapsible section containing optional `base_url` and schema-declared `provider_options` generated from that provider's `provider_schema/0`. Boolean options render as switches, finite enums as selects, numeric options as number inputs, simple strings as text inputs, and complex map/list options as per-field JSON textareas. There is no global free-form `provider_options` JSON box; unknown options are not valid configuration.
   - "Test" button → `POST /setup/llm/providers/check` → shows pong response or error inline.
2. **Model aliases section.** Four rows, one per model alias. Each row shows the current effective binding. `:default` is required and presents a `Select` of endpoint names. `:fast`, `:heavy`, and `:compression` can bind to an endpoint or reuse another model alias. The default UI selection is `:fast -> :default`, `:heavy -> :default`, and `:compression -> :fast`; `:compression` may also be set to reuse `:default`.

Save button is disabled until:
- At least one LLM model endpoint exists.
- `:default` is bound to one of the endpoints in the list (referential validity).
- The non-default model alias graph is acyclic.
- Every endpoint has a non-empty `provider_id` and `model_id`; blank `name` is filled as `provider_id/model_id` before validation.
- Every submitted `provider_options` key belongs to the selected vendor's req_llm provider schema and every submitted value has the schema-required shape.

`api_key` is **not** required at save time and is not shown for providers that do not declare a conventional inline API-key path. Several req_llm providers do not consume an inline API key:

- `:vllm` — self-hosted, accepts any non-empty value or none if the server is unauthenticated; usually configured via OS env (`OPENAI_API_KEY=any-value-for-vllm`).
- `:amazon_bedrock` — uses AWS credentials, typically through IAM role / `AWS_BEARER_TOKEN_BEDROCK` / standard AWS env vars rather than an inline key.
- `:google_vertex` — uses a service-account JSON file (`GOOGLE_APPLICATION_CREDENTIALS` path) rather than a key string.
- `:openai_codex` — OAuth-based; credentials live in an `oauth_file` referenced via `provider_options`; the global API key field is not rendered.

Operators with these providers leave `api_key` blank and let req_llm pick up its native auth from OS env or schema-declared `provider_options`. Operators with conventional key-bearing providers (`:anthropic`, `:openai`, etc.) enter the key into the field; the save path encrypts and stores it. The UI explains this tradeoff inline near the field — it does not enforce a one-size-fits-all "must enter key" rule.

Save → `POST /setup/llm/providers` → on success, the server redirects to `/setup/gateway`.

Operators who already completed phase 2 and re-visit `/setup/llm` see their existing configuration and can edit it. The page does not enforce read-only mode for "completed" phases — the wizard treats every phase as resumable until owner activation closes setup.

## 11. Tests

### 11.1 `test/bullx/ext_test.exs`

Modify the existing file (or create one if absent) to add roundtrip tests for `aead_encrypt/2` and `aead_decrypt/2`:

- Encrypt → decrypt yields the original binary.
- Two encryptions of the same plaintext produce different ciphertexts (random nonce).
- Decrypting with a wrong key returns `{:error, _}`, not a crash.
- Decrypting a malformed ciphertext returns `{:error, _}`.
- Decrypting a ciphertext truncated by one byte returns `{:error, _}` (AEAD tag).

### 11.2 `test/bullx_ai_agent/llm/crypto_test.exs`

- `derive_provider_key/1` returns a 64-char hex string and is deterministic for a fixed `BULLX_SECRET_BASE` and provider id.
- Different provider ids yield different keys.
- `encrypt_api_key/2` and `decrypt_api_key/2` roundtrip a non-empty plaintext.
- `decrypt_api_key/2` returns `{:error, _}` when called with a different provider id than the one used to encrypt.

### 11.3 `test/bullx_ai_agent/llm/writer_test.exs`

- `put_provider/1` with an `:api_key` writes a row whose `encrypted_api_key` is non-nil and decrypts back to the original plaintext.
- `put_provider/1` without an `:api_key` writes a row with `encrypted_api_key = nil`.
- `update_provider/2` without `:api_key` in the attrs leaves `encrypted_api_key` untouched; passing `:api_key => nil` clears it.
- `delete_provider/1` returns `{:error, {:still_referenced_by_alias, alias_name}}` when an alias still points at it.
- `put_alias_binding(:default, {:alias, :fast})` returns `{:error, {:default_alias_must_target_provider, :default}}`.
- `put_alias_binding(:heavy, {:alias, :default})` succeeds when it does not create a cycle.
- `put_alias_binding/2` rejects alias cycles, including cycles that involve implicit fallbacks.
- `put_alias_binding(:fast, {:provider, "absent"})` returns `{:error, {:unknown_provider, "absent"}}`.

### 11.4 `test/bullx_ai_agent/llm/catalog_test.exs`

- The cache is populated on boot; `list_providers/0` and `list_alias_bindings/0` reflect seeded rows.
- `resolve_alias(:default)` returns the seeded provider's resolved provider struct, with req_llm model fields in `model` and DB-derived request options in `opts`.
- `resolve_alias(:heavy)` returns the `:heavy` provider when bound directly to a provider.
- `resolve_alias(:compression)` can reuse `:fast` via an alias binding, and can explicitly reuse `:default` via `:compression -> :default`.
- `resolve_alias/1` resolves unbound `:fast` and `:heavy` by directly reusing the resolved `:default` provider, and resolves unbound `:compression` by directly reusing the resolved `:fast` provider.
- `resolve_alias/1` returns `{:error, {:decrypt_failed, _}}` when the bound provider's ciphertext fails to decrypt (simulated by writing garbage into `encrypted_api_key` directly via `BullX.Repo`). The error is **not** silently downgraded to a fallback.
- `refresh_provider/1` and `refresh_alias/1` invalidate the cache for a single key without reloading the full table.

ETS isolation and sandbox visibility follow the same rules as RFC 0001 §9.2: each test that writes through the writer must `Ecto.Adapters.SQL.Sandbox.allow/3` the cache process, and an `on_exit` hook calls `BullXAIAgent.LLM.Catalog.Cache.refresh_all/0` so subsequent tests see the rolled-back database.

### 11.5 `test/bullx_ai_agent/model_aliases_test.exs`

- `aliases/0` returns `[:default, :fast, :heavy, :compression]`.
- `alias?/1` returns `true` for the four and `false` for everything else (including the legacy aliases).
- `resolve_model(:default | :fast | :heavy | :compression)` succeeds when `:default` is bound to a provider.
- `resolve_model/1` raises `ArgumentError` for `:capable`, `:thinking`, `:image`, `:embedding`, and any other atom.
- With an empty DB, `resolve_model(:default)` raises `{:not_configured, :default}` (or the wrapper exception form).
- With only `:default` bound (no rows for fast/heavy/compression), `resolve_model(:fast)`, `resolve_model(:heavy)`, and `resolve_model(:compression)` resolve to the same provider struct as `:default` because `:compression` falls through via unbound `:fast`.
- With `:default` and `:fast` bound to different providers and no `:compression` row, `resolve_model(:compression)` resolves to the same provider struct as `:fast`, not `:default`.
- `Writer.put_alias_binding(:fast, {:alias, :compression})` returns `{:error, {:alias_cycle, _}}` when `:compression` is still implicitly falling back to `:fast`.

### 11.6 `test/bullx/config/req_llm_bridge_test.exs`

- Writing `BullX.Config.put("bullx.req_llm.receive_timeout_ms", "12345")` causes `Application.get_env(:req_llm, :receive_timeout)` to equal `12345` synchronously after `BullX.Config.put/2` returns.
- Writing `BullX.Config.put("bullx.req_llm.debug", "true")` causes `Application.get_env(:req_llm, :debug)` to flip to `true`.
- Provider-specific keys (`:anthropic_api_key`, etc.) are not bridged: setting `bullx.req_llm.anthropic_api_key` has no effect on `Application.get_env(:req_llm, :anthropic_api_key)`.
- After `Bridge.sync_all!/0` runs, every key in `BullX.Config.ReqLLM.bridge_keyspec/0` is present in `Application.get_all_env(:req_llm)`.

### 11.7 `test/bullx/application_test.exs`

Modify the existing file to add assertions:

- `BullXAIAgent.Supervisor` is alive and is a direct child of `BullX.Application`'s top-level supervisor.
- `BullXAIAgent.LLM.Catalog.Cache` is alive and is a child of `BullXAIAgent.Supervisor`.
- `Application.get_env(:req_llm, :load_dotenv)` is `false`.
- `Application.get_env(:req_llm, :receive_timeout)` is non-nil by the time `BullXAIAgent.Supervisor` is alive, proving the boot-time bridge sync completed before downstream subsystem startup.

### 11.8 `test/bullx_web/controllers/setup_controller_test.exs`

Modify the existing file to cover the redirector:

- With bootstrap session valid and `:default` unbound: `GET /setup` redirects to `/setup/llm`.
- With bootstrap session valid, `:default` bound, no enabled adapter: `GET /setup` redirects to `/setup/gateway`.
- With bootstrap session valid and both LLM and gateway phases complete: `GET /setup` redirects to `/setup/activate-owner`.
- With bootstrap session invalid: `GET /setup` redirects to `/setup/sessions/new` and drops the session.

### 11.9 `test/bullx_web/controllers/setup_llm_controller_test.exs` (new)

- `GET /setup/llm` with valid bootstrap session renders the setup-llm SPA with the catalog and current providers/aliases.
- `POST /setup/llm/providers/check` with a valid provider attrs payload calls into a stubbed `BullXAIAgent.generate_text/2` and returns the stub's response. With an invalid attrs payload, returns `{ok: false, errors: [...]}` without calling generate_text.
- `POST /setup/llm/providers` with `:default` bound to a provider in the payload persists everything and returns `{ok: true, redirect_to: "/setup/gateway"}`. The `llm_providers` row is decryptable via `BullXAIAgent.LLM.Crypto.decrypt_api_key/2`.
- `POST /setup/llm/providers` with an incomplete provider row returns `{ok: false, errors: [...]}` and persists nothing.
- `POST /setup/llm/providers` without a `:default` binding returns `{ok: false, errors: [...]}` and persists nothing.
- `POST /setup/llm/providers` whose `:default` points at a provider name not in the payload returns `{ok: false, errors: [...]}` and persists nothing.
- `POST /setup/llm/providers` with non-default alias targets persists those alias bindings when the final graph is acyclic.
- `POST /setup/llm/providers` with a circular alias graph returns `{ok: false, errors: [...]}` and persists nothing.
- `POST /setup/llm/providers` with a row carrying `api_key_inherits_from` and no `api_key`, when the named source is a previously saved provider with a stored key, persists the new row with an `encrypted_api_key` that decrypts (under the *new* provider's id) to the same plaintext as the source's stored key. The new row's id differs from the source's.
- `POST /setup/llm/providers` with two rows where the second carries `api_key_inherits_from` pointing at the first's freshly submitted `:api_key` plaintext (in-batch source) persists both rows; the new row's `encrypted_api_key` decrypts to the in-batch plaintext.
- `POST /setup/llm/providers` with `api_key_inherits_from` referencing an unknown source returns `{ok: false, errors: [...]}` with the field set to `api_key_inherits_from` and persists nothing.

## 12. Non-Goals and Invariants

The executing agent must not:

- Place provider catalog code under `BullX.Config.*`.
- Store plaintext API keys in `llm_providers`.
- Bridge provider-specific `req_llm` keys (`:anthropic_api_key`, `:azure_api_key`, etc.) into `Application.put_env(:req_llm, …)` from `BullX.Config`.
- Bridge `:custom_providers` or `:load_dotenv` through `BullX.Config.ReqLLM` or any other DB layer.
- Accept call-level BullXAIAgent `:api_key`, `:base_url`, or `:provider_options`; provider configuration comes from `llm_providers` only.
- Accept direct req_llm inline model specs as normal BullXAIAgent provider configuration. Normal call sites use aliases; setup-time provider check uses a transient `ResolvedProvider` built from the submitted row.
- Introduce a fifth alias atom anywhere in the codebase.
- Re-introduce `:image`, `:embedding`, `:capable`, `:thinking`, `:reasoning`, or `:planning` aliases as compatibility shims.
- Modify the upstream `req_llm` package.
- Add a key-rotation procedure for `BULLX_SECRET_BASE`. Rotation is unsupported and the deployment must be treated as if the master secret were immutable.
- Add a web console for provider management.
- Place `BullXAIAgent.LLM.Catalog.Cache` outside `BullXAIAgent.Supervisor`.
- Make `BullX.Config.ReqLLM.Bridge` a GenServer or any other long-lived process. It is a plain module; the boot-time sync runs through `BullX.Config.ReqLLM.BootSync`, which returns `:ignore` after the synchronous sync.
- Add an `enabled` boolean or a `description` text column to `llm_providers`. Either is a feature creep that this RFC explicitly excludes.

The executing agent must preserve these invariants:

- The set of allowed alias atoms is exactly `{:default, :fast, :heavy, :compression}`. `:default` must bind directly to a provider.
- `llm_alias_bindings` rows are constrained by Postgres `CHECK` to the allowed alias set, the allowed target kind set, the exactly-one-target shape, and `:default` provider-only targeting.
- Alias-to-alias binding is accepted only for non-default aliases and only when the effective alias graph is acyclic.
- `encrypted_api_key` is the only place an API key is persisted, and it is always XChaCha20-Poly1305 ciphertext keyed by `BullX.Ext.derive_key(secret_base, "llm_providers/" <> uuid, "api_key")`.
- `BullXAIAgent.Supervisor` is the failure boundary for `BullXAIAgent.LLM.Catalog.Cache` and any future AIAgent runtime worker.
- The boot-time `BullX.Config.ReqLLM.Bridge.sync_all!/0` runs synchronously through `BullX.Config.ReqLLM.BootSync` after `BullX.Config.Cache` starts and before `BullX.Config.Supervisor.start_link/1` returns.
- `:load_dotenv` is `false` in every environment. `:custom_providers` is registered exclusively through `BullXAIAgent.LLM.register_custom_providers/0`.

## 13. Acceptance Criteria

A coding agent has completed this RFC when all of the following hold:

1. `mix deps.get` succeeds without changes to `mix.exs`.
2. `cd native/bullx_ext && cargo build` succeeds with the new `chacha20poly1305` dependency.
3. `mix ecto.migrate` creates `llm_providers` and `llm_alias_bindings` with the schema and constraints described in §5.
4. `mix compile --warnings-as-errors` succeeds.
5. `mix format --check-formatted` succeeds.
6. `mix test` passes, including all new tests in §11.
7. `mix precommit` passes end-to-end.
8. `BullX.Ext.aead_encrypt/2` and `BullX.Ext.aead_decrypt/2` roundtrip arbitrary binaries with a 64-char hex key.
9. After boot, `BullXAIAgent.Supervisor` is alive as a child of `BullX.Application`'s top-level supervisor, `BullXAIAgent.LLM.Catalog.Cache` is its child, and the ETS tables `:bullx_llm_providers` and `:bullx_llm_alias_bindings` exist and are populated from the database.
10. `BullXAIAgent.ModelAliases.aliases/0` returns exactly `[:default, :fast, :heavy, :compression]`.
11. `BullXAIAgent.ModelAliases.resolve_model(:capable)` raises `ArgumentError`.
12. Calling `BullXAIAgent.LLM.Writer.put_provider/1` with an `:api_key` results in a `llm_providers` row whose `encrypted_api_key` decrypts back to the original plaintext via `BullXAIAgent.LLM.Crypto.decrypt_api_key/2`.
13. With `:default` bound to a provider and no other alias rows, `resolve_alias(:fast)`, `resolve_alias(:heavy)`, and `resolve_alias(:compression)` all return the same resolved provider as `resolve_alias(:default)` because `:compression` falls through via unbound `:fast`.
13a. With `:default` and `:fast` bound to different providers and no `:compression` row, `resolve_alias(:compression)` returns the same resolved provider as `resolve_alias(:fast)`, not `resolve_alias(:default)`.
14. With `:default` unbound, `resolve_alias(:default)` returns `{:error, {:not_configured, :default}}` and `BullXAIAgent.LLM.Catalog.default_alias_configured?/0` returns `false`.
15. Calling `put_alias_binding(:default, {:alias, :fast})` returns `{:error, {:default_alias_must_target_provider, :default}}`; calling `put_alias_binding(:heavy, {:alias, :default})` succeeds when `:default` is configured; calling `put_alias_binding(:fast, {:alias, :compression})` returns `{:error, {:alias_cycle, _}}` while `:compression` still implicitly falls back to `:fast`.
16. After `BullX.Config.put("bullx.req_llm.receive_timeout_ms", "12345")`, `Application.get_env(:req_llm, :receive_timeout)` is `12345` synchronously after `put/2` returns; same for `:debug`.
17. `grep -r "BullXAIAgent.config\b" lib test` returns no matches.
18. `grep -rE ":(capable|thinking|reasoning|planning|image|embedding)\b" lib/bullx_ai_agent` returns no matches outside doc strings explicitly describing the removal.
19. `Application.get_env(:req_llm, :load_dotenv)` returns `false` in `dev`, `test`, and `prod`.
20. `BullXAIAgent.LLM.register_custom_providers/0` exists, returns `:ok`, and registers `BullXAIAgent.LLM.Providers.VolcengineArk` as `:volcengine_ark` and `BullXAIAgent.LLM.Providers.XiaomiMiMo` as `:xiaomi_mimo`. It is invoked exactly once during `BullXAIAgent.Supervisor.init/1`.
21. `lib/bullx_ai_agent/reasoning/agentic_loop/token.ex` no longer exists. `grep -rn "checkpoint_token\|token_secret\|AgenticLoop.Token" lib/bullx_ai_agent` returns no matches. No `BullX.Config.AIAgent` module exists.
22. Visiting `/setup` after authenticating the bootstrap session redirects to `/setup/llm` when `:default` is unbound, to `/setup/gateway` when `:default` is bound but no enabled adapter exists, and to `/setup/activate-owner` when both LLM and gateway phases are complete.
23. GET `/setup/gateway` renders the gateway channel setup SPA for an authenticated setup session.
24. `POST /setup/llm/providers/check` with valid endpoint attrs succeeds and returns the LLM's pong-style response. `POST /setup/llm/providers` rejects incomplete endpoint rows and schema-invalid vendor-specific options before any write; with complete endpoints and an endpoint-backed `:default` model alias binding, it persists the providers, persists the `:default` alias binding, and returns `{ok: true, redirect_to: "/setup/gateway"}`.

If any criterion fails, the RFC is not complete.
