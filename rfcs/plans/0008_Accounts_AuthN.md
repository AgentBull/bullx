# RFC 0008: BullXAccounts AuthN

- **Author**: Boris Ding
- **Created**: 2026-04-24

## 1. TL;DR

BullXAccounts AuthN is the identity and login boundary for BullX. It maps external Gateway channel actors to durable BullX users, controls first-time activation, and gives the Web control plane a session-establishing login path.

This RFC defines four durable concepts:

1. **Users.** A BullX user is the system identity used by Web, Runtime, and future authorization checks. `email`, `phone`, and `username` are global unique fields. BullXAccounts does not introduce tenants.
2. **Channel bindings.** A user can bind many Gateway channel actors. The stable binding key is `{adapter, channel_id, external_id}`, where `external_id` is Gateway `actor.id`.
3. **Activation codes.** Short-lived, single-use preauth credentials let an unbound channel actor self-activate when automatic matching is not sufficient.
4. **User channel auth codes.** Short-lived, single-use out-of-band codes let an already bound active channel actor establish a Web cookie session through `/web_auth`.

Key decisions:

- BullXAccounts is an L2 subsystem under `lib/bullx_accounts/` with top-level module namespace `BullXAccounts`.
- Gateway signals continue to carry channel-local actors only. Gateway does not add BullX user ids to inbound signals.
- Runtime and other business code resolve a channel actor to a BullX user through BullXAccounts when identity is needed.
- Web login uses standard Phoenix cookie sessions. JWTs are not an AuthN session mechanism in this RFC.
- AuthZ is deliberately separate. This RFC does not create groups, group memberships, grants, Cedar policy evaluation, or permission caches. First-user administrator treatment is owned by the AuthZ RFC.

### 1.1 Cleanup plan

- **Dead code to delete**
  - None in this RFC. BullXAccounts does not currently exist in `lib/`.
- **Duplicate logic to merge / patterns to reuse**
  - Reuse `BullX.Repo` and Ecto schemas for all durable AuthN state.
  - Reuse `BullX.Ecto.UUIDv7` for UUID primary keys.
  - Reuse `BullX.Config` for match rules, activation requirements, and auth-code TTLs.
  - Reuse `BullX.Ext.argon2_hash/1` and `BullX.Ext.argon2_verify/2` for activation-code and user-channel-auth-code hashing.
  - Add `BullX.Ext.phone_normalize_e164/1` on top of `rlibphonenumber` for phone-number validation and canonicalization; reuse it from the user changeset and any future phone-bearing schema.
  - Reuse Gateway's existing channel actor shape: `actor.id`, `actor.display`, and `actor.bot`.
  - Reuse Phoenix browser sessions for Web login instead of inventing JWT or token-session storage.
- **Actual code paths / schemas / documents changing**
  - New L2 subsystem modules under `lib/bullx_accounts/`.
  - New AuthN tables: `users`, `user_channel_bindings`, `activation_codes`, and `user_channel_auth_codes`.
  - New configuration declarations under `BullX.Config.Accounts`.
  - New Web login controller/view paths for provider login and channel-auth-code login.
  - New one-shot bootstrap activation-code check during application startup.
  - Gateway adapter command handlers call BullXAccounts for `/preauth <code>` and `/web_auth`.
- **Invariants that must remain true**
  - Process-local AuthN state is reconstructible from PostgreSQL.
  - A banned user cannot log in through Web, resolve from Gateway binding, or run as a Runtime business identity.
  - Activation and channel-auth codes are stored only as hashes; plaintext codes are returned only at creation time.
  - Activation codes are retained after use for audit; user channel auth codes are deleted after successful consumption.
  - Gateway remains transport-oriented and does not become the owner of BullX user identity.
  - AuthZ remains a separate design boundary.
- **Verification commands**
  - `mix test test/bullx_accounts`
  - `mix test test/bullx_web/controllers/session_controller_test.exs`
  - `mix precommit`

## 2. Scope

### 2.1 In scope

- BullX user schema and user status semantics.
- Channel actor binding to BullX users.
- Trusted channel profile matching on first contact.
- Controlled user creation and binding with activation codes.
- `/preauth <code>` handling for duplex Gateway channels.
- Web control-plane login through Gateway login providers.
- Web control-plane login through `/web_auth` channel auth codes.
- Cookie session establishment for BullXWeb.
- AuthN configuration through `BullX.Config`.
- Bootstrap behavior needed for first-user activation.

### 2.2 Out of scope

- Cedar policy evaluation, permission grants, permission caches, computed groups, and authorization APIs.
- Generic OIDC, SAML, or OAuth provider support implemented by BullXAccounts itself.
- A BullX-wide tenant model.
- JWT-based browser sessions.
- User-initiated activation approval queues.
- Rate limiting and attempt-count limiting for activation-code or auth-code entry.
- Long-lived remember-me tokens, API tokens, service accounts, and personal access tokens.
- Multi-node cache invalidation beyond the guarantees already provided by `BullX.Config` and PostgreSQL.

## 3. Subsystem Placement

BullXAccounts is an L2 subsystem because user identity and login are first-class concerns used by Web, Gateway, Runtime, and AuthZ.

- **Path:** `lib/bullx_accounts/`
- **Top-level module:** `BullXAccounts`
- **OTP application:** the existing `:bullx` application
- **Database:** the existing `BullX.Repo`

No long-lived AuthN process is required for the first implementation. The subsystem is mostly Ecto schemas, pure matching rules, transactional command functions, and a one-shot startup bootstrap check. Do not add an empty `BullXAccounts.Supervisor`. If a later design adds session cleanup workers, provider refresh workers, or async audit delivery, that design must state the new failure boundary explicitly.

Phoenix-specific login controllers and plugs live under `lib/bullx_web/`. Gateway adapter command handling stays in adapter-owned modules and calls BullXAccounts as an application service.

## 4. Identity Model

### 4.1 BullX users

`users` is the durable identity table. A user is active or banned:

- `active`: allowed to log in, resolve from Gateway bindings, and run as a Runtime business identity.
- `banned`: locked. Web login, Gateway binding resolution, and Runtime business use must all fail.

`email`, `phone`, and `username` are global unique fields. They are nullable because not every channel provides every profile field. If present, `phone` is stored in E.164 format.

The first successfully created user is only an AuthN user in this RFC. AuthN does not create an `admin` group, does not create group memberships, and does not write authorization grants. AuthZ owns first-user administrator semantics in its own RFC.

### 4.2 Gateway channel identity

Gateway `actor` remains channel-local:

- `actor.id` maps to `user_channel_bindings.external_id`.
- `actor.display` is the external display name.
- `actor.bot` indicates whether the channel actor is a bot.

Gateway must not add a BullX user id to inbound signal data. That keeps Gateway transport-oriented and avoids making every inbound event carry business identity whether it needs it or not.

When business code needs identity, it calls BullXAccounts with:

```elixir
BullXAccounts.resolve_channel_actor(adapter, channel_id, external_id)
```

The result must be an active user, a banned-user error, or a not-bound error.

### 4.3 Channel bindings

Each BullX user can have many channel bindings. The binding key is:

```text
{adapter, channel_id, external_id}
```

`adapter` is the Gateway adapter type, for example `feishu` or `telegram`. `channel_id` identifies a concrete adapter channel instance and supports multiple channels of the same adapter type. It is not a tenant id. `external_id` is Gateway `actor.id`.

The binding stores raw channel identity/profile metadata in `metadata`. This metadata is audit and troubleshooting context; durable matching fields that become BullX user attributes must be copied to `users`.

## 5. Matching And Activation

### 5.1 Trusted profile input

On first contact, a channel may provide trusted profile fields such as email, phone, username, external org id, or display name. Not all channels can provide these fields. Adapter code must pass only trusted fields to BullXAccounts. Untrusted or user-editable channel display text must not be used as identity proof.

The matching input is a normalized map, not a platform-specific payload:

```elixir
%{
  adapter: :feishu,
  channel_id: "workplace-main",
  external_id: "ou_xxx",
  profile: %{
    "email" => "user@example.com",
    "phone" => "+8613800000000",
    "username" => "alice",
    "org_id" => "tenant_xxx",
    "display_name" => "Alice"
  },
  metadata: %{}
}
```

### 5.2 Short-circuit matching rules

BullXAccounts evaluates configured match rules in order. The first successful rule wins, and later rules are not evaluated. If different candidate fields would match different existing users, the configured priority decides the result. There is no conflict-review workflow in this RFC.

Match rules are runtime configuration managed by `BullX.Config`. The configured value is JSON-compatible data so operators can edit it through the control plane or environment variables. Rules are declarative data; they must not parse arbitrary module/function strings from config.

A matching rule has an explicit result:

- `bind_existing_user`: find an existing BullX user from trusted channel identity, then create a channel binding for that user.
- `allow_create_user`: decide that the trusted channel identity is eligible for automatic user creation when no existing binding or existing-user match has already won.

Initial rule operations:

- `equals_user_field`: compare a trusted source path to a unique user field such as `email`, `phone`, or `username`; result is `bind_existing_user`.
- `email_domain_in`: allow automatic creation when a trusted email's domain is in an allowlist; result is `allow_create_user`.
- `equals_any`: allow automatic creation when a trusted source path equals one of a configured set of values, for example `metadata.org_id`; result is `allow_create_user`.

Example shape:

```json
[
  {
    "result": "bind_existing_user",
    "op": "equals_user_field",
    "source_path": "profile.email",
    "user_field": "email"
  },
  {
    "result": "bind_existing_user",
    "op": "equals_user_field",
    "source_path": "profile.phone",
    "user_field": "phone"
  },
  {
    "result": "allow_create_user",
    "op": "email_domain_in",
    "source_path": "profile.email",
    "domains": ["example.com"]
  },
  {
    "result": "allow_create_user",
    "op": "equals_any",
    "source_path": "metadata.org_id",
    "values": ["tenant_xxx"]
  }
]
```

`source_path` reads from the normalized channel input. It is not limited to user fields; adapter-normalized metadata such as `metadata.org_id` is valid when the adapter marks it trusted.

### 5.3 User creation policy

For an unbound channel actor, BullXAccounts follows this order:

1. If a `bind_existing_user` rule matches an active user, create a new binding for that user. Automatic binding happens regardless of `accounts_authn_auto_create_users`, because binding is not creation.
2. If a `bind_existing_user` rule matches a banned user, reject with `:user_banned` and stop evaluating later rules.
3. If an `allow_create_user` rule matches and `accounts_authn_auto_create_users` is true, create a new user and first channel binding.
4. If an `allow_create_user` rule matches but `accounts_authn_auto_create_users` is false, fall through to the unmatched-creation policy below (the rule is ignored for creation).
5. If no rule matches, follow the unmatched-creation policy below.

This is the only self-service path for adding multiple channel bindings to the same user: a later channel actor must automatically match an existing user through trusted profile data. Activation codes do not attach additional channel actors to existing users. Future manual binding management, if needed, belongs to the Web/admin surface and is not part of `/preauth`.

The unmatched-creation policy combines two switches:

- `accounts_authn_auto_create_users`: whether automatic creation from trusted profile data is allowed. When false, BullXAccounts never auto-creates a user; activation codes remain the only creation path.
- `accounts_authn_require_activation_code`: whether an unmatched actor is told to activate. Only evaluated when `accounts_authn_auto_create_users` is true.

Resolution:

- `auto_create_users = true, require_activation_code = false`: create the user and binding in one transaction.
- `auto_create_users = true, require_activation_code = true`: return `:activation_required`.
- `auto_create_users = false`: return `:activation_required` regardless of `require_activation_code`. Activation codes still work (see §5.4).

### 5.4 Activation codes

Activation codes control unmatched new-user registration and the new user's first binding. They are closer to Tailscale preauth keys than recipient-bound invitations:

- single-use
- short-lived
- revocable
- stored as `code_hash`
- retained after use for audit
- not tied to a specific email or channel actor

Administrators can create activation codes through Web UI or IM command surfaces. Code creation time is the authorization point. Consuming a valid code does not require a second approver.

When a channel actor cannot be matched and activation is required, BullX should send an outbound message equivalent to:

```text
The current account cannot be linked to BullX automatically. Contact an administrator for an activation code, then send /preauth <code> to activate.
```

`/preauth <code>` is self-service activation for the current channel actor when automatic matching did not bind or create a user. After code validation, BullXAccounts creates a new BullX user from the trusted profile and creates that user's first channel binding for the current `{adapter, channel_id, external_id}`.

Activation-code consumption is independent of `accounts_authn_auto_create_users`. An admin issuing an activation code is an explicit authorization to create a user; the `auto_create_users` switch only governs non-admin, rule-driven creation. An activation code always permits creating a new user and first binding, even when `auto_create_users` is false.

Activation-code consumption must not be used to attach a channel actor to an existing user. If the actor is already bound, return the existing binding state. If the actor now matches an existing user through automatic matching, use the automatic matching path instead and do not consume the activation code. Both guards remain in effect regardless of `auto_create_users`.

The code consumption, user creation, and binding creation must happen in one database transaction. Concurrent attempts to consume the same activation code must result in exactly one success.

User-initiated approval requests are deferred. If real workflow pressure appears, introduce a separate `activation_requests` table and HITL queue in a later RFC.

### 5.5 Bootstrap activation code

On application startup, BullXAccounts performs a one-shot bootstrap check with a supervised transient worker placed after `BullX.Repo` and `BullX.Config.Supervisor` in the application child list:

1. If the `users` table is empty and there is no valid unexpired activation code, create one activation code with `created_by_user_id = nil`.
2. Log the plaintext activation code once through `Logger`.
3. If a valid unexpired activation code already exists, do not create or log a replacement.
4. If AuthN tables do not exist yet, skip the check and log a warning instead of crashing the application before migrations can run.

This worker exits normally after the check and is not a long-lived AuthN process. It is only a bootstrap escape hatch for a new deployment where no administrator exists yet.

## 6. Web Login

The Web control plane supports two login paths.

### 6.1 Gateway login providers

A Gateway channel may declare that its adapter supports Web login provider capability. The provider protocol can be OIDC-like, SAML-like, or platform-private. BullXAccounts does not implement a generic OIDC/SAML provider abstraction in this RFC.

The adapter must normalize provider-returned identity data to the same channel identity/profile semantics used by IM-side binding:

- `adapter`
- `channel_id`
- `external_id`
- trusted profile fields such as `email`, `phone`, `username`, and adapter-specific org identifiers

BullXAccounts then applies the same matching rules used by IM-side identity handling:

1. If the provider identity has an existing channel binding, log in as that user when active.
2. If a `bind_existing_user` rule matches an active user, create the provider channel binding and log in as that user.
3. If an `allow_create_user` rule matches and user creation is enabled, create a new user plus provider channel binding and log in as the new user.
4. If no rule matches, do not create a Web session. Tell the user to activate from a duplex channel with `/preauth <code>` first.

Provider login changes only how the Web session is established; it does not change channel binding semantics and does not bypass the matching/activation policy.

For Feishu enterprise self-built apps, IM activation through bot DM or group messages defaults to trusted profile matching such as org id, email suffix, and phone. Failed matching falls back to activation code. Feishu Web login may be offered at the same time, but its returned `external_id`, org id, email, and phone must normalize to the same semantics as the IM profile.

### 6.2 User channel auth codes

Channels without a Web login provider can still establish Web sessions if they are duplex. An active bound user sends:

```text
/web_auth
```

BullXAccounts creates a short-lived one-time user channel auth code and sends it back over the current channel. The user enters that code on the Web login page. BullXWeb consumes the code and establishes a normal cookie-based Phoenix session.

User channel auth codes are Device Code Flow-like, but they are an internal BullX mechanism. They prove that an already bound active user controls the current channel. They do not register or bind unbound actors.

`/web_auth` is valid only when `{adapter, channel_id, external_id}` resolves to an active BullX user. If the actor is unbound, the adapter should use automatic matching or `/preauth <code>` activation flow instead. If the user is banned, no auth code is issued.

Auth-code characters are uppercase letters and digits with visually confusing characters removed. Length is a code constant. TTL is `BullX.Config` runtime configuration. The system stores only `code_hash`. Successful consumption deletes the row immediately.

This RFC intentionally does not add rate limiting or attempt-count limiting. That omission is acceptable for the first implementation but should be revisited before exposing BullX to hostile public traffic.

### 6.3 Web sessions

BullXWeb stores the logged-in user id in the Phoenix session. Every authenticated Web request reloads the user through BullXAccounts and rejects missing or banned users. Session state is not the source of truth.

JWT is not used for browser login sessions in this RFC. API token design, service accounts, and personal access tokens are separate work.

## 7. Data Model

All UUID primary keys use:

```elixir
@primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
```

Migrations must not add PostgreSQL-side UUID defaults such as `gen_random_uuid()`.

### 7.1 `users`

Columns:

- `id`: UUIDv7 primary key.
- `username`: globally unique username, nullable.
- `email`: globally unique email, nullable. Stored lowercased and trimmed. Basic format is validated at the changeset level.
- `phone`: globally unique phone number in E.164 format, nullable. Validated with the libphonenumber-backed NIF `BullX.Ext.phone_normalize_e164/1`; the stored value is the canonical E.164 form returned by that function.
- `display_name`: display name.
- `avatar_url`: avatar URL, nullable.
- `status`: native PostgreSQL enum `user_status` with values `active` and `banned`. Mapped in Ecto with `Ecto.Enum`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Indexes and constraints:

- unique index on `username` where `username IS NOT NULL`
- unique index on `email` where `email IS NOT NULL`
- unique index on `phone` where `phone IS NOT NULL`
- native PostgreSQL enum type `user_status` enforces the legal set of status values; no separate CHECK constraint is added

### 7.2 `user_channel_bindings`

Columns:

- `id`: UUIDv7 primary key.
- `user_id`: foreign key to `users.id`.
- `adapter`: Gateway adapter type.
- `channel_id`: concrete adapter channel instance id.
- `external_id`: Gateway channel actor external id.
- `metadata`: JSONB raw channel profile/context data.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Indexes and constraints:

- unique index on `{adapter, channel_id, external_id}`
- index on `user_id`

### 7.3 `activation_codes`

Columns:

- `id`: UUIDv7 primary key.
- `code_hash`: PHC-formatted Argon2id activation-code hash, unique.
- `expires_at`: expiration timestamp.
- `created_by_user_id`: nullable foreign key to `users.id`.
- `revoked_at`: nullable revocation timestamp.
- `used_at`: nullable consumption timestamp.
- `used_by_adapter`: nullable Gateway adapter type.
- `used_by_channel_id`: nullable channel id.
- `used_by_external_id`: nullable channel actor external id.
- `metadata`: JSONB creation or consumption context.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

A code is valid when:

```sql
revoked_at IS NULL AND used_at IS NULL AND expires_at > now()
```

The implementation should enforce single-use consumption with an atomic update scoped to this validity predicate.

### 7.4 `user_channel_auth_codes`

Columns:

- `id`: UUIDv7 primary key.
- `code_hash`: PHC-formatted Argon2id auth-code hash, unique.
- `user_id`: foreign key to `users.id`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Validity is computed from `inserted_at` and the configured TTL. A successfully consumed auth code is deleted. The table does not store temporary state for unbound channel actors.

### 7.5 Code hashing

Activation codes and user channel auth codes use the same hashing boundary:

- On creation, store `BullX.Ext.argon2_hash(plaintext_code)` in `code_hash`.
- On consumption, verify a submitted plaintext code with `BullX.Ext.argon2_verify(plaintext_code, code_hash)`.
- Treat `{:error, reason}` from either function as a failed closed AuthN operation and log the reason at debug or warning level according to caller context.

`BullX.Ext.argon2_hash/1` returns a salted PHC-formatted Argon2id string. Because the hash is salted, the implementation must not try to recompute a deterministic hash and query by equality on `code_hash`. Instead, load the bounded set of currently valid candidate rows, verify each candidate with `BullX.Ext.argon2_verify/2`, and then consume only the matching row inside the transaction. If candidate volume becomes a real problem, introduce a separate non-secret lookup selector in a later RFC.

Do not use `BullX.Ext.generic_hash/2`, `BullX.Ext.bs58_hash/2`, or a database-side digest for these codes.

## 8. Configuration

AuthN runtime configuration lives under `BullX.Config.Accounts`.

Initial settings:

- `accounts_authn_match_rules`: JSON-compatible ordered rule list. Default: `[]`.
- `accounts_authn_auto_create_users`: boolean. Default: `true`. Governs only automatic, rule-driven user creation. Activation-code consumption is not affected by this switch.
- `accounts_authn_require_activation_code`: boolean. Default: `true`. Only consulted when `accounts_authn_auto_create_users` is true; it decides whether an unmatched actor receives an activation prompt or is auto-created from trusted profile data.
- `accounts_activation_code_ttl_seconds`: positive integer. Default: `86400`.
- `accounts_web_auth_code_ttl_seconds`: positive integer. Default: `300`.

With the defaults, a fresh deployment is closed to arbitrary automatic user creation unless a trusted match rule is configured. The startup bootstrap check creates and logs one activation code so the first user can still activate.

All settings follow RFC 0001 resolution semantics: PostgreSQL override, OS environment, application config, then default. Invalid higher-priority values are skipped rather than treated as terminal failures.

`accounts_authn_match_rules` must be cast and validated as data. Invalid rules are ignored as invalid config values, causing resolution to fall back to the next configuration layer.

## 9. Public API Shape

The public facade is `BullXAccounts`. Internal helper modules may live under `BullXAccounts.AuthN`, but callers should not need to compose Ecto schema modules directly.

Expected public functions:

```elixir
@spec resolve_channel_actor(atom() | String.t(), String.t(), String.t()) ::
        {:ok, BullXAccounts.User.t()}
        | {:error, :not_bound}
        | {:error, :user_banned}

@spec match_or_create_from_channel(map()) ::
        {:ok, BullXAccounts.User.t(), BullXAccounts.UserChannelBinding.t()}
        | {:error, :activation_required}
        | {:error, :user_banned}
        | {:error, term()}

@spec create_activation_code(BullXAccounts.User.t() | nil, map()) ::
        {:ok, %{code: String.t(), activation_code: BullXAccounts.ActivationCode.t()}}
        | {:error, Ecto.Changeset.t()}

@spec consume_activation_code(String.t(), map()) ::
        {:ok, BullXAccounts.User.t(), BullXAccounts.UserChannelBinding.t()}
        | {:error, :invalid_or_expired_code}
        | {:error, :already_bound}
        | {:error, :auto_match_available}
        | {:error, term()}

@spec issue_user_channel_auth_code(atom() | String.t(), String.t(), String.t()) ::
        {:ok, String.t()}
        | {:error, :not_bound}
        | {:error, :user_banned}
        | {:error, term()}

@spec consume_user_channel_auth_code(String.t()) ::
        {:ok, BullXAccounts.User.t()}
        | {:error, :invalid_or_expired_code}
        | {:error, :user_banned}
```

Schema modules:

- `BullXAccounts.User`
- `BullXAccounts.UserChannelBinding`
- `BullXAccounts.ActivationCode`
- `BullXAccounts.UserChannelAuthCode`

Web modules:

- `BullXWeb.SessionController`
- `BullXWeb.SessionHTML`
- `BullXWeb.Plugs.FetchCurrentUser`
- `BullXWeb.Plugs.RequireAuthenticatedUser`

Gateway adapters should expose `/preauth` and `/web_auth` as adapter command handling, then call `BullXAccounts` rather than duplicating AuthN logic.

## 10. Implementation Plan

### 10.1 New files

- `lib/bullx_accounts.ex`
- `lib/bullx_accounts/authn.ex`
- `lib/bullx_accounts/user.ex`
- `lib/bullx_accounts/user_channel_binding.ex`
- `lib/bullx_accounts/activation_code.ex`
- `lib/bullx_accounts/bootstrap.ex`
- `lib/bullx_accounts/user_channel_auth_code.ex`
- `lib/bullx_accounts/code.ex`
- `lib/bullx_accounts/changeset.ex`
- `lib/bullx/config/accounts.ex`
- `lib/bullx_web/controllers/session_controller.ex`
- `lib/bullx_web/controllers/session_html.ex`
- `lib/bullx_web/controllers/session_html/new.html.heex`
- `lib/bullx_web/plugs/fetch_current_user.ex`
- `lib/bullx_web/plugs/require_authenticated_user.ex`
- `native/bullx_ext/src/phone.rs`
- `priv/repo/migrations/20260424000000_create_accounts_authn_tables.exs`
- `test/bullx_accounts/authn_test.exs`
- `test/bullx_accounts/schema_test.exs`
- `test/bullx_web/controllers/session_controller_test.exs`

### 10.2 Modified files

- `lib/bullx/application.ex`
- `lib/bullx_web/router.ex`
- `config/config.exs`
- `test/support/conn_case.ex`
- `test/support/data_case.ex`
- `lib/bullx/ext.ex` (add the `phone_normalize_e164/1` shim)
- `native/bullx_ext/src/lib.rs` (register the phone module)
- `native/bullx_ext/Cargo.toml` (add the `rlibphonenumber` dependency)

Modify `BullX.Application` only to add the one-shot transient `BullXAccounts.Bootstrap` worker after `BullX.Repo` and `BullX.Config.Supervisor`. Do not add a long-lived AuthN supervisor.

### 10.3 Implementation sequence

1. Add migration and schemas for the four AuthN tables.
2. Add `BullX.Config.Accounts` and casting/validation for AuthN settings.
3. Add code generation and hashing helpers in `BullXAccounts.Code`.
4. Add the startup bootstrap activation-code check.
5. Implement binding resolution and banned-user checks.
6. Implement short-circuit matching, including existing-user binding rules and automatic creation allow rules.
7. Implement transactional match/create/bind behavior.
8. Implement activation-code creation, revocation, and atomic consumption for new-user activation only.
9. Implement user channel auth-code issuance and consumption.
10. Add Web session routes, controller actions, and plugs.
11. Connect adapter command handlers to BullXAccounts after concrete adapters exist.
12. Add tests for schemas, transactions, config fallback, Web sessions, bootstrap activation code, and command-facing AuthN behavior.

## 11. Testing

Tests must prove:

1. UUID primary keys use `BullX.Ecto.UUIDv7`.
2. Unique user fields allow many null values but reject duplicate non-null values.
3. `{adapter, channel_id, external_id}` is unique.
4. Active bound users resolve successfully.
5. Banned users fail Web login and channel resolution.
6. Matching rules short-circuit in configured order.
7. `bind_existing_user` rules create additional channel bindings for active users and halt with `:user_banned` on a banned match.
8. `allow_create_user` rules create a new user and first binding when `accounts_authn_auto_create_users` is true.
9. `accounts_authn_auto_create_users = false` returns `:activation_required` for both rule-matched and unmatched channel flows, and does not block activation-code consumption.
10. Required activation returns activation-required only when no automatic binding or creation path succeeds.
11. Activation-code consumption creates a new user and first binding, not an additional binding to an existing user.
12. Activation-code consumption is single-use under concurrent attempts.
13. Revoked, expired, used, or unknown activation codes fail.
14. Activation codes and user channel auth codes are hashed with `BullX.Ext.argon2_hash/1` and verified with `BullX.Ext.argon2_verify/2`.
15. Startup creates and logs one activation code when both users and valid activation codes are absent.
16. Provider login follows the same binding/creation/activation decisions as channel matching.
17. `/web_auth` issuance fails for unbound or banned actors.
18. User channel auth codes expire by TTL and are deleted on successful consumption.
19. Web login stores only session identity and reloads the durable user on authenticated requests.
20. Invalid email format and invalid phone number format are rejected at the changeset level; a valid phone is normalized to canonical E.164 before storage.
21. `/logout` clears the session and redirects to `/login`.

## 12. Acceptance Criteria

1. `BullXAccounts` exists as an L2 namespace under `lib/bullx_accounts/`.
2. AuthN tables persist users, channel bindings, activation codes, and user channel auth codes.
3. All UUID primary keys are application-generated UUIDv7 values.
4. Gateway actor identity remains channel-local; BullX user id resolution happens in BullXAccounts.
5. Active users can resolve through channel bindings.
6. Banned users cannot resolve, log in, or receive Web auth codes.
7. Activation-code and auth-code plaintext values are never stored.
8. Activation-code consumption is transactional and single-use.
9. Activation-code and auth-code hashes use `BullX.Ext.argon2_hash/1`; submitted codes are checked with `BullX.Ext.argon2_verify/2`.
10. Activation-code consumption creates a new user and first binding only; it never attaches a new channel actor to an existing user, and is not blocked by `accounts_authn_auto_create_users = false`.
11. Provider login does not create a Web session when no existing binding, existing-user rule, or automatic creation rule matches.
12. User channel auth-code consumption establishes a Phoenix cookie session and deletes the code.
13. `users.status` is backed by the native PostgreSQL enum type `user_status`; email and phone fields are format-validated at the changeset layer, and phone values are normalized to canonical E.164 via `BullX.Ext.phone_normalize_e164/1` before storage.
14. AuthZ implementation remains completely outside this RFC.
15. `mix precommit` passes.
