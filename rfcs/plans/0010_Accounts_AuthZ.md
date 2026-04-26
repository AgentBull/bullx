# RFC 0010: BullXAccounts AuthZ

**Status**: Implementation plan  
**Author**: Boris Ding  
**Created**: 2026-04-26  
**Depends on**: RFC 0001, RFC 0005, RFC 0008

## 1. TL;DR

BullXAccounts AuthZ is the authorization boundary for durable BullX users. It decides whether an active AuthN user may perform an action on a resource under a request context.

This RFC implements the authorization framework first. It does not define BullX's concrete application policy catalog, does not require Web/Gateway/Runtime code paths to enforce specific policy names, and does not seed application-specific permission grants.

This RFC adds three concepts to the `BullXAccounts` L2 subsystem:

1. **Groups.** Static groups are administrator-managed; computed groups are evaluated from a small JSON expression language and cached locally as reconstructible state.
2. **Permission grants.** IAM-style resource-pattern plus action grants assigned to users or groups.
3. **Condition language.** A grant's Cedar `condition` expression can reference caller-provided authorization context under `context.request`.

Key decisions:

- AuthZ extends the existing `BullXAccounts` subsystem. It does not introduce a new OTP application or move AuthN ownership.
- RFC 0008 remains the source of truth for users, channel bindings, activation codes, Web login, and session establishment.
- AuthZ consumes RFC 0008 users. It does not create channel bindings, issue auth codes, establish sessions, or change Gateway actor semantics.
- Banned users are denied before group expansion, cache lookup, or Cedar evaluation.
- The built-in `admin` static group is seeded by AuthZ, but AuthZ does not decide which user should be an administrator.
- The first implementation targets BullX's current single-node deployment model. AuthZ cache invalidation is local and reconstructible.
- Gateway signals continue to carry channel-local actors only. Business code resolves a BullX user through AuthN and then asks AuthZ for authorization when needed.
- Permission caches are performance hints. PostgreSQL remains the system of record, and all cached state must be safe to rebuild.

### 1.1 Cleanup Plan

- **Dead code to delete**
  - None. AuthZ does not currently have committed modules or tables to remove.
- **Duplicate logic to merge / patterns to reuse**
  - Reuse RFC 0008 `users` as the only human principal source.
  - Reuse the `BullXAccounts` facade instead of introducing a separate public subsystem facade.
  - Reuse `BullX.Repo`, Ecto schemas, and `BullX.Ecto.UUIDv7` for durable AuthZ state.
  - Reuse `BullX.Config.Accounts` for AuthZ runtime settings.
  - Reuse the `BullX.Config.Cache` pattern for a local ETS cache owner process.
  - Reuse the existing `BullX.Ext` / `native/bullx_ext` Rustler crate for the Cedar Rust NIF boundary.
  - Reuse Phoenix plugs from RFC 0008 by layering AuthZ checks after authenticated user loading.
- **Actual code paths / schemas / processes changing**
  - New AuthZ tables: `user_groups`, `user_group_memberships`, and `permission_grants`.
  - New AuthZ modules under `lib/bullx_accounts/` and `lib/bullx_accounts/authz/`.
  - New native Cedar module inside the existing `native/bullx_ext/` crate.
  - `BullXAccounts` gains AuthZ facade delegates.
  - `BullX.Application` starts a reconstructible AuthZ cache owner process after `BullX.Config.Supervisor`.
  - `BullXAccounts.AuthZ.Bootstrap` ensures built-in AuthZ framework seed data after migrations exist.
- **Invariants that must remain true**
  - AuthN owns identity, login, channel binding, and session establishment.
  - AuthZ owns groups, permission grants, authorization decisions, and permission caches.
  - A banned user is never authorized, even if a direct user grant or group grant would otherwise allow the request.
  - Computed group memberships are never written to `user_group_memberships`.
  - Cedar parse errors, evaluation errors, and non-boolean Cedar results fail closed for that grant.
  - Multiple grants use short-circuit allow semantics: any applicable grant that evaluates to `true` authorizes the request.
  - There is no explicit deny grant in this RFC.
  - Runtime grant data is never evaluated as Elixir code, AST, or module/function strings.
  - Request `resource` and `action` remain strings; AuthZ must not convert caller-provided names to atoms.
  - Local cache loss or process restart cannot lose durable authorization data.
- **Verification commands**
  - `mix test test/bullx_accounts/authz_test.exs`
  - `mix test test/bullx_accounts/authz_schema_test.exs`
  - `mix test test/bullx_accounts/authn_test.exs`
  - `mix precommit`

## 2. Scope

### 2.1 In Scope

- Static user groups.
- Computed user groups.
- Static group membership management.
- Permission grants assigned to users or groups.
- IAM-style resource-pattern plus action authorization requests.
- Cedar boolean condition evaluation for grants.
- Caller-provided authorization context normalization.
- Local reconstructible group and decision caches.
- Built-in `admin` group seed data.
- Public AuthZ functions on `BullXAccounts`.

### 2.2 Out of Scope

- Login, activation, channel binding, provider login, `/preauth`, and `/web_auth`; these remain RFC 0008 AuthN behavior.
- Gateway signal contract changes.
- A BullX tenant model.
- Service accounts, API tokens, personal access tokens, and machine principals.
- Concrete application policy names and enforcement integrations for Web, Gateway, Runtime, Skills, Brain, or AIAgent.
- Explicit deny grants and deny precedence.
- A complete resource catalog for Gateway, Runtime, Skills, Brain, or AIAgent.
- Full Web UI for managing groups and grants.
- User-initiated authorization request workflows.
- Fine-grained cache invalidation by dependency graph.
- Administrator onboarding and setup workflows.

## 3. Subsystem Placement

AuthZ belongs to `BullXAccounts`, the same L2 subsystem introduced by RFC 0008.

- **Path:** `lib/bullx_accounts/`
- **Top-level module:** `BullXAccounts`
- **OTP application:** the existing `:bullx` application
- **Database:** the existing `BullX.Repo`

AuthZ adds one long-lived process: `BullXAccounts.AuthZ.Cache`. It owns local ETS tables for reconstructible cache entries. This is a performance boundary, not a durable authority. If the process crashes, the supervisor restarts it with an empty cache and future authorization requests reload from PostgreSQL.

No AuthZ supervisor is added for these two children. Mount `BullXAccounts.AuthZ.Cache` directly under `BullX.Supervisor`, after `BullX.Repo` and `BullX.Config.Supervisor`.

`BullXAccounts.AuthZ.Bootstrap` is a separate one-shot transient task. Mount it after `BullXAccounts.AuthZ.Cache` and before the RFC 0008 `BullXAccounts.Bootstrap` activation-code task:

```text
BullX.Repo
BullX.Config.Supervisor
BullXAccounts.AuthZ.Cache
BullXAccounts.AuthZ.Bootstrap
BullXAccounts.Bootstrap
```

`BullXAccounts.Bootstrap` remains the AuthN bootstrap activation-code owner. It does not seed AuthZ groups or grants.

If AuthZ tables do not exist yet, `BullXAccounts.AuthZ.Bootstrap` logs a warning, exits normally, and does not block application boot before migrations can run.

Phoenix-specific enforcement plugs or controller checks live under `lib/bullx_web/` and call `BullXAccounts.authorize/4`. They do not own authorization policy.

## 4. AuthN Boundary

RFC 0008 remains the owner of authentication and user lifecycle. AuthZ consumes durable users as principals and does not change AuthN's ownership.

### 4.1 User Lifecycle

AuthN creates and updates users. AuthZ observes those users as principals.

RFC 0010 adds one AuthN-owned user status helper to close the cache invalidation path:

```elixir
BullXAccounts.update_user_status(user_or_id, :active | :banned)
```

The helper updates `users.status` and invalidates AuthZ caches in the same application-level code path. Direct `Repo.update` calls that change `users.status` are out-of-contract for cache correctness.

AuthZ must not:

- create users as a side effect of authorization;
- create channel bindings;
- issue activation codes;
- issue user channel auth codes;
- establish Web sessions;
- infer a BullX user from a Gateway actor;
- decide the setup or onboarding workflow that grants a user membership in `admin`.

Callers that start from Gateway identity must first call RFC 0008 functions such as:

```elixir
BullXAccounts.resolve_channel_actor(adapter, channel_id, external_id)
```

Only after an active user is available should they call AuthZ.

### 4.2 Banned Users

`users.status = :banned` is an AuthN field with AuthZ consequences. `BullXAccounts.authorize/4` must reload or validate the user and deny banned users before evaluating any grant.

This means a stale session or stale caller-held `%User{}` struct cannot authorize a banned user.

## 5. Authorization Model

### 5.1 Request Shape

Authorization asks whether one user can perform one action on one resource:

```elixir
%BullXAccounts.AuthZ.Request{
  user_id: user.id,
  resource: "gateway_channel:workplace-main",
  action: "write",
  context: %{"adapter" => "feishu"}
}
```

`resource` and `action` are non-empty strings. `action` must not contain `:` because permission keys split at the final `:`. They are never converted to atoms, because callers may pass external request data. `context` is Cedar-context-compatible data supplied by the caller. In v1 that means booleans, strings, signed 64-bit integers, lists, and maps with string or atom keys; atom keys are stringified, lists are passed to Cedar as sets, and map keys are recursively normalized to strings. `nil`, JSON `null`, floats, structs, PIDs, tuples, functions, and other BEAM terms make the request invalid. AuthZ wraps caller-provided context under `context.request`; caller keys are not merged into the top-level Cedar context.

The public API accepts either separate resource/action arguments or a permission key:

```elixir
BullXAccounts.authorize(user, "web_console", "read")
BullXAccounts.authorize(user, "gateway_channel:workplace-main", "write", %{})
BullXAccounts.authorize_permission(user, "gateway_channel:workplace-main:write", %{})
```

Permission keys split at the final `:`. Everything before it is the resource; everything after it is the action. This allows resources such as `gateway_channel:<channel_id>` without introducing ARN syntax.

### 5.2 Resource Patterns

Grants use resource patterns, not a global resource table. Resource and action names are application-defined strings. This RFC only defines parsing and matching rules; later policy work decides which concrete strings Web, Gateway, Runtime, Skills, Brain, and AIAgent enforce.

Example permission keys:

- `web_console:read`
- `web_console:write`
- `gateway_channel:<channel_id>:write`
- `gateway_channel:*:write`
- `gateway_channel:workplace-*:write`

`*` is the only wildcard. A v1 pattern may contain zero or one `*`; grant writes reject patterns with more than one wildcard. `*` matches any character sequence inside the resource string, including `:`. This differs from AWS ARN matching, where `:` is a segment boundary. All other characters match literally. There is no `**`, character class, regular expression, or hierarchy-specific operator.

Examples:

| Grant resource pattern | Action | Request resource | Request action | Result |
| --- | --- | --- | --- | --- |
| `web_console` | `read` | `web_console` | `read` | match |
| `web_console` | `write` | `web_console` | `read` | no match |
| `gateway_channel:*` | `write` | `gateway_channel:workplace-main` | `write` | match |
| `gateway_channel:*` | `write` | `gateway_channel:foo:bar` | `write` | match |
| `gateway_channel:ops` | `write` | `gateway_channel:workplace-main` | `write` | no match |

Actions do not imply each other. If `write` should also allow `read`, create both grants.

### 5.3 Decision Flow

`BullXAccounts.authorize/4` follows this order:

1. Normalize the request.
2. Load the current user from PostgreSQL when the caller passes an id or stale struct.
3. Return `{:error, :not_found}` if the user is missing, or `{:error, :user_banned}` if the user is banned.
4. Check the local decision cache when caching is enabled.
5. Expand the user's static and computed groups.
6. Fetch grants assigned directly to the user or to any expanded group.
7. Filter grants by action and resource pattern.
8. For each applicable grant:
   1. evaluate the Cedar boolean condition with the normalized request context;
   2. return allow on the first `true`.
9. Deny when no grant evaluates to `true`.
10. Cache allow/forbidden decisions according to `accounts_authz_cache_ttl_ms`.

Errors during grant evaluation affect only that grant. They do not crash the authorization request and do not authorize the request.

Nil users, malformed user ids, empty resource strings, empty action strings, and non-Cedar-context-compatible contexts return `{:error, :invalid_request}`. Well-formed ids that do not identify a user return `{:error, :not_found}`. These cases must not raise.

When decision caching is enabled, the cache key must include:

- `user_id`
- normalized `resource`
- normalized `action`
- a canonical hash of caller-supplied `context`

The context hash is computed after request normalization using recursively sorted string keys. List order remains part of the hash; this can create harmless extra cache misses, but never a stale allow.

Authorization conditions that depend on Elixir-side facts must receive those facts through caller-supplied context. Because the normalized caller context is part of the decision-cache key, there is no separate cache rule for dynamic facts. Callers are responsible for including every fact that can affect the Cedar condition, such as an IP whitelist match or business-hours result.

`{:error, :not_found}`, `{:error, :user_banned}`, and `{:error, :invalid_request}` results are not decision-cached. Only normalized requests for existing active users reach the decision cache.

## 6. Groups

### 6.1 Static Groups

Static groups are administrator-managed. Their memberships are persisted in `user_group_memberships`.

The built-in `admin` group is static and protected:

- AuthZ bootstrap creates it idempotently.
- It cannot be deleted through the public AuthZ API.
- Its `built_in` flag is system-owned and cannot be set or cleared through public group create/update APIs.
- It can receive normal static memberships after bootstrap.

### 6.2 Computed Groups

Computed groups are dynamic. Their membership is evaluated from `computed_expression` and may be cached, but it is not written to `user_group_memberships`.

The first expression language is JSON-compatible data with these operations:

- `and`: all child expressions must be true.
- `or`: at least one child expression must be true.
- `not`: the child expression must be false.
- `group_member`: the user must be a member of another group.
- `user_status`: the user must have a given `users.status`.

Example:

```json
{
  "op": "and",
  "args": [
    {"op": "group_member", "group": "admin"},
    {"op": "user_status", "eq": "active"}
  ]
}
```

Expression shapes:

- `{"op": "and", "args": [expr, ...]}`: all child expressions must be true. `args` must be a non-empty list.
- `{"op": "or", "args": [expr, ...]}`: at least one child expression must be true. `args` must be a non-empty list.
- `{"op": "not", "arg": expr}`: the child expression must be false. Exactly one `arg` is required.
- `{"op": "group_member", "group": "admin"}`: the user must be a member of the named group. `group` must be a non-empty string.
- `{"op": "user_status", "eq": "active"}`: the user must have the given `users.status`. `eq` must be `active` or `banned`.

Expression rules:

- Expressions are data, not Elixir code.
- Group references use the stable `user_groups.name` value. Group names and group types are immutable after creation.
- Write-time validation rejects `group_member` references to unknown groups.
- Runtime unknown groups evaluate to `false` if persisted data drifts because of manual database edits or validation changes, and are reported as invalid persisted computed-group data.
- `group_member` checks static membership first. If the referenced group is computed, AuthZ recursively evaluates that group's expression with a visited-set guard.
- Malformed expression shapes, unknown operations, empty `and` / `or` args, invalid `not` arity, and invalid `user_status` values are rejected by the `user_groups` changeset on create/update.
- Runtime still treats invalid persisted expressions as `false`. This protects the system during deploys, manual database edits, or validation changes. Malformed shapes, unknown group references, and cycles encountered at runtime must emit `Logger.error/1` and telemetry event `[:bullx, :authz, :invalid_persisted_data]`; normal expressions that simply evaluate to `false` must not emit that event.
- The write path rejects cycles across existing group rows. Runtime still guards recursive evaluation; if a cycle is encountered, the current branch returns `false`.
- Public group deletion rejects deleting a group referenced by any computed expression with `{:error, :group_in_use}`. Callers must update or delete dependent computed groups first.
- Static group membership can be referenced by computed groups.
- Computed group membership can reference another computed group as long as no cycle exists.

### 6.3 Cache Invalidation

The first implementation uses coarse invalidation:

- Any group create/update/delete invalidates all AuthZ cache entries.
- Any static membership add/remove invalidates all AuthZ cache entries.
- Any permission grant create/update/delete invalidates all AuthZ cache entries.
- Any user status change must invalidate all AuthZ cache entries.

This is intentionally simple. Do not build a dependency graph for computed groups in the first implementation.

Cache entries are derived from normalized database rows and request data. They must not contain caller-supplied atoms, Elixir AST, or dynamically resolved module/function references.

Decision-cache entries are keyed by normalized request shape as described in §5.3. Computed-group cache entries are keyed by `user_id` and store the currently true computed group ids for that user. Both cache types are invalidated by the coarse invalidation rules above.

## 7. Permission Grants

### 7.1 Grant Semantics

A permission grant assigns an allow condition to exactly one principal:

- one user; or
- one group.

The schema uses separate nullable `user_id` and `group_id` columns rather than a polymorphic `principal_type` and `principal_id` pair. This lets PostgreSQL enforce real foreign keys for both principal types.

A grant is applicable when:

1. its principal is the request user or one of that user's groups;
2. its `action` equals the request action;
3. its `resource_pattern` matches the request resource.

After applicability is established, its Cedar `condition` expression is evaluated. A grant with `condition = "true"` is unconditional after resource/action matching. Empty conditions are invalid. No matching grant means deny.

Multiple grants are combined with allow-any semantics. There is no deny grant and no grant priority in this RFC.

### 7.2 Built-in Admin Group

AuthZ bootstrap creates the built-in `admin` group only. It does not create application-specific permission grants in this RFC.

The `admin` group is deliberately not magical. It authorizes nothing until a later RFC, operator seed, or test fixture attaches normal `permission_grants` rows to it. Membership assignment belongs to setup or operator workflows and uses normal static membership APIs.

The built-in `admin` group cannot be deleted through the public AuthZ API. Public membership APIs must reject removing the final static member from the built-in `admin` group with `{:error, :last_admin_member}`.

## 8. Cedar Conditions

### 8.1 Boundary

BullX uses the Cedar Rust SDK through the `cedar-policy` crate and exposes it through a Rust NIF in `BullX.Ext`. Cedar's formal policy language calls a complete `permit` or `forbid` statement a policy. BullX permission grants do not store complete Cedar policies. They store the boolean expression that BullX wraps as a Cedar `when` condition after BullX has already matched the grant principal, resource pattern, and action.

The Cedar NIF lives in the existing `native/bullx_ext` Rustler crate and is exported through the existing `BullX.Ext` module. Do not create a second native application, a second Rustler crate, or a separate Elixir NIF facade. Add `cedar.rs` under `native/bullx_ext/src/`, register it from `native/bullx_ext/src/lib.rs`, and add the Cedar Rust dependency to `native/bullx_ext/Cargo.toml`.

AuthZ code should call an Elixir wrapper, not the NIF directly:

```elixir
BullXAccounts.AuthZ.Cedar.validate_condition(condition)
BullXAccounts.AuthZ.Cedar.evaluate(condition, request)
```

The Elixir wrapper returns:

```elixir
@spec validate_condition(String.t()) :: :ok | {:error, String.t()}

@spec evaluate(String.t(), BullXAccounts.AuthZ.Request.t()) ::
        {:ok, boolean()} | {:error, String.t()}
```

The NIF shim follows the existing `BullX.Ext` convention and returns a raw boolean on success or `{:error, reason}` on failure:

```elixir
@spec BullX.Ext.cedar_condition_validate(String.t()) ::
        true | {:error, String.t()}

@spec BullX.Ext.cedar_condition_eval(String.t(), map()) ::
        boolean() | {:error, String.t()}
```

`BullXAccounts.AuthZ.Cedar` must catch `:erlang.nif_error(:nif_not_loaded)` and other NIF boundary failures and convert them to `{:error, reason}`. Authorization callers must see a failed grant, not a process crash, when the Cedar NIF is unavailable.

The wrapper builds one synthetic Cedar policy:

```cedar
permit(principal, action, resource)
when {
  <condition>
};
```

`<condition>` is the exact grant condition string. It is parsed by Cedar. It is never interpreted as Elixir code.

The request is passed to the NIF as normalized data:

```elixir
%{
  "principal" => %{
    "type" => "BullXUser",
    "id" => user_id,
    "attrs" => %{
      "id" => user_id,
      "status" => "active"
    }
  },
  "action" => %{
    "type" => "BullXAction",
    "id" => action
  },
  "resource" => %{
    "type" => "BullXResource",
    "id" => resource
  },
  "context" => cedar_context
}
```

The Rust side must construct Cedar `EntityUid` / request values through Cedar SDK constructors rather than interpolating request strings into the policy source. This is the escaping rule for arbitrary BullX resource/action strings. Only the condition string is policy source.

The wrapper builds the Cedar evaluation input from:

- principal: the active BullX user id and status;
- action: the request action string;
- resource: the request resource string;
- context: a map with the normalized caller context under `request`.

Group membership is intentionally not exposed as a Cedar principal attribute in v1. Group logic selects applicable grants before Cedar runs; conditions should express request-time facts, not repeat group matching.

The Cedar context shape is:

```elixir
%{
  "request" => caller_context
}
```

Elixir-side facts needed by a condition are precomputed by the caller and passed in `caller_context`. Cedar conditions read them from `context.request`, for example:

```cedar
context.request.business_hours && context.request.ip_whitelisted
```

The default principal context should not expose email, phone, channel metadata, or other profile fields. Callers that need profile-sensitive policy must pass explicit, already-approved context values.

The first implementation is schema-less Cedar evaluation. Grant writes still parse the synthetic policy through Cedar for syntax validation. A future RFC may add a Cedar schema; that RFC must define the entity and context schema and migration behavior for existing grants.

Because BullX stores only a condition expression but Cedar parses complete policies, the wrapper must reject synthetic policy parsing results unless they contain exactly one `permit(principal, action, resource)` policy, no `forbid`, no template, no additional policy, one `when` clause, no `unless` clause, and exactly the supplied condition as that policy's `when` expression. This prevents a condition string from closing the `when` block and injecting a second policy.

Both Cedar NIFs run on the dirty CPU scheduler. The Rust NIF functions must return ordinary values or `{:error, String.t()}` to Elixir and must not panic on malformed policy source or malformed request maps.

### 8.2 Failure Semantics

Grant condition evaluation fails closed:

- Cedar parse error -> grant does not allow.
- Cedar evaluation error -> grant does not allow.
- Cedar result is not boolean -> grant does not allow.
- Cedar NIF unavailable -> grant does not allow.
- Cedar decision `Allow` -> `{:ok, true}`.
- Cedar decision `Deny` with no evaluation error -> `{:ok, false}`.

The authorization request continues to evaluate other applicable grants after a grant-level failure.

### 8.3 Condition Validation

Grant writes validate `condition` through the Cedar wrapper before insertion or update. Validation errors return changeset errors and do not write invalid grants.

Runtime still treats an invalid persisted condition as a failed grant. This protects the system during deploys, manual database edits, or NIF behavior changes. Invalid persisted conditions must emit `Logger.error/1` and telemetry event `[:bullx, :authz, :invalid_persisted_data]`; a valid condition that evaluates to `false` must not emit that event.

## 9. Caller Context Facts

AuthZ does not execute Elixir predicate functions from permission grants. When a condition depends on Elixir-side request context, the enforcing code computes the required fact before calling AuthZ and passes it in the request context.

Examples:

- A Phoenix plug checks whether the client IP is in an application whitelist and passes `"ip_whitelisted" => true`.
- A Gateway handler checks a channel's runtime state and passes `"channel_open" => true`.
- A business workflow computes whether the current time is inside an allowed window and passes `"business_hours" => true`.

Those facts are normalized with the rest of the caller context and exposed to Cedar under `context.request`:

```elixir
BullXAccounts.authorize(user, "gateway_channel:workplace-main", "write", %{
  "ip_whitelisted" => true,
  "business_hours" => true
})
```

```cedar
context.request.ip_whitelisted && context.request.business_hours
```

The caller context is part of the decision-cache key. If a Cedar condition depends on a dynamic fact, the caller must include that fact in context. AuthZ does not infer missing facts and does not run grant-configured Elixir callbacks during authorization.

A missing or wrongly typed context field causes Cedar evaluation to fail closed for that grant. This is not automatically invalid persisted data: the condition may be valid for a different enforcement path with a different context contract.

Conditions that intentionally accept optional caller facts should use Cedar `has` checks before reading the field, for example `context.request has ip_whitelisted && context.request.ip_whitelisted`.

### 9.1 Invalid Persisted Data Event

Runtime validation failures caused by persisted AuthZ rows use one telemetry event:

```elixir
[:bullx, :authz, :invalid_persisted_data]
```

Measurements:

```elixir
%{count: 1}
```

Metadata:

```elixir
%{
  kind: :computed_group | :condition,
  id: Ecto.UUID.t(),
  reason: term()
}
```

This event is for persisted data that should have been rejected by write-time validation but is encountered at runtime. It must not be emitted for ordinary authorization denials, valid computed groups that evaluate to `false`, or valid Cedar conditions that evaluate to deny.

## 10. Data Model

All UUID primary keys use:

```elixir
@primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
```

Migrations must not add PostgreSQL-side UUID defaults such as `gen_random_uuid()`.

### 10.1 `user_groups`

Columns:

- `id`: UUIDv7 primary key.
- `name`: stable group key, globally unique.
- `type`: native PostgreSQL enum `user_group_type` with values `static` and `computed`.
- `description`: nullable text.
- `computed_expression`: nullable JSONB.
- `built_in`: boolean, default `false`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints:

- `name` is unique and non-empty.
- `name` and `type` are immutable after insert at the changeset/API layer.
- `built_in` is system-owned; public create/update changesets must ignore or reject caller-supplied `built_in`.
- `type = 'static'` requires `computed_expression IS NULL`.
- `type = 'computed'` requires `computed_expression IS NOT NULL`.

### 10.2 `user_group_memberships`

Columns:

- `user_id`: foreign key to `users.id`.
- `group_id`: foreign key to `user_groups.id`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints:

- composite primary key on `{user_id, group_id}`;
- cascade delete when the user or group is deleted.

This table stores static memberships only. Public AuthZ functions must reject attempts to add or remove memberships for computed groups.

This invariant is application-enforced. PostgreSQL cannot enforce it with a simple foreign key or CHECK constraint because it depends on `user_groups.type`; this RFC does not add a trigger for that rule. Direct database writes to this table are out-of-contract.

### 10.3 `permission_grants`

Columns:

- `id`: UUIDv7 primary key.
- `user_id`: nullable foreign key to `users.id`.
- `group_id`: nullable foreign key to `user_groups.id`.
- `resource_pattern`: non-empty text.
- `action`: non-empty text that must not contain `:`.
- `condition`: Cedar boolean expression string. Default: `true`.
- `description`: nullable text.
- `metadata`: JSONB, default `{}`.
- `inserted_at`: creation timestamp.
- `updated_at`: update timestamp.

Constraints:

- exactly one of `user_id` or `group_id` must be non-null;
- `resource_pattern` must contain at most one `*`;
- `action` must not contain `:`;
- indexes on `user_id`, `group_id`, and `{action, resource_pattern}`;
- foreign keys cascade on deleted users or groups.

The schema validates that `condition` parses as a Cedar boolean expression.

## 11. Configuration

AuthZ runtime configuration lives in `BullX.Config.Accounts` next to the AuthN settings from RFC 0008.

Initial settings:

- `accounts_authz_cache_ttl_ms`: non-negative integer. Default: `60_000`. `0` disables decision and computed-group caching.

All settings follow RFC 0001 resolution semantics: PostgreSQL override, OS environment, application config, then default. Invalid higher-priority values are skipped and resolution continues to the next layer.

## 12. Public API Shape

The public facade remains `BullXAccounts`.

`list_user_groups/1` returns the user's currently effective groups: persisted static memberships plus computed groups whose expressions evaluate to `true` at call time. It does not write computed memberships to `user_group_memberships`.

Expected public functions:

```elixir
@spec authorize(BullXAccounts.User.t() | Ecto.UUID.t(), String.t(), String.t()) ::
        :ok
        | {:error, :forbidden}
        | {:error, :not_found}
        | {:error, :user_banned}
        | {:error, :invalid_request}

@spec authorize(BullXAccounts.User.t() | Ecto.UUID.t(), String.t(), String.t(), map()) ::
        :ok
        | {:error, :forbidden}
        | {:error, :not_found}
        | {:error, :user_banned}
        | {:error, :invalid_request}

@spec authorize_permission(BullXAccounts.User.t() | Ecto.UUID.t(), String.t()) ::
        :ok
        | {:error, :forbidden}
        | {:error, :not_found}
        | {:error, :user_banned}
        | {:error, :invalid_request}

@spec authorize_permission(BullXAccounts.User.t() | Ecto.UUID.t(), String.t(), map()) ::
        :ok
        | {:error, :forbidden}
        | {:error, :not_found}
        | {:error, :user_banned}
        | {:error, :invalid_request}

@spec allowed?(BullXAccounts.User.t() | Ecto.UUID.t(), String.t(), String.t()) ::
        boolean()

@spec allowed?(BullXAccounts.User.t() | Ecto.UUID.t(), String.t(), String.t(), map()) ::
        boolean()

@spec list_user_groups(BullXAccounts.User.t() | Ecto.UUID.t()) ::
        {:ok, [BullXAccounts.UserGroup.t()]} | {:error, term()}

@spec create_user_group(map()) ::
        {:ok, BullXAccounts.UserGroup.t()} | {:error, Ecto.Changeset.t()}

@spec update_user_group(BullXAccounts.UserGroup.t() | Ecto.UUID.t(), map()) ::
        {:ok, BullXAccounts.UserGroup.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}

@spec delete_user_group(BullXAccounts.UserGroup.t() | Ecto.UUID.t()) ::
        :ok | {:error, :not_found} | {:error, :built_in_group} | {:error, :group_in_use}

@spec add_user_to_group(BullXAccounts.User.t() | Ecto.UUID.t(), BullXAccounts.UserGroup.t() | Ecto.UUID.t()) ::
        :ok | {:error, :not_found} | {:error, :computed_group} | {:error, Ecto.Changeset.t()}

@spec remove_user_from_group(BullXAccounts.User.t() | Ecto.UUID.t(), BullXAccounts.UserGroup.t() | Ecto.UUID.t()) ::
        :ok | {:error, :not_found} | {:error, :computed_group} | {:error, :last_admin_member}

@spec update_user_status(BullXAccounts.User.t() | Ecto.UUID.t(), :active | :banned) ::
        {:ok, BullXAccounts.User.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}

@spec create_permission_grant(map()) ::
        {:ok, BullXAccounts.PermissionGrant.t()} | {:error, Ecto.Changeset.t()}

@spec update_permission_grant(BullXAccounts.PermissionGrant.t() | Ecto.UUID.t(), map()) ::
        {:ok, BullXAccounts.PermissionGrant.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}

@spec delete_permission_grant(BullXAccounts.PermissionGrant.t() | Ecto.UUID.t()) ::
        :ok | {:error, :not_found}
```

Internal modules may live under `BullXAccounts.AuthZ`, but Web, Gateway, Runtime, Skills, and Brain should call the facade.

`authorize/3`, `authorize_permission/2`, and `allowed?/3` are convenience functions that use an empty context `%{}`.

## 13. Implementation Plan

### 13.1 New Files

- `lib/bullx_accounts/authz.ex`
- `lib/bullx_accounts/authz/bootstrap.ex`
- `lib/bullx_accounts/authz/cache.ex`
- `lib/bullx_accounts/authz/cedar.ex`
- `lib/bullx_accounts/authz/computed_group.ex`
- `lib/bullx_accounts/authz/request.ex`
- `lib/bullx_accounts/authz/resource_pattern.ex`
- `lib/bullx_accounts/permission_grant.ex`
- `lib/bullx_accounts/user_group.ex`
- `lib/bullx_accounts/user_group_membership.ex`
- `native/bullx_ext/src/cedar.rs`
- `priv/repo/migrations/20260426000000_create_accounts_authz_tables.exs`
- `test/bullx_accounts/authz_test.exs`
- `test/bullx_accounts/authz_schema_test.exs`

### 13.2 Modified Files

- `lib/bullx_accounts.ex`
- `lib/bullx_accounts/authn.ex`
- `lib/bullx/application.ex`
- `lib/bullx/config/accounts.ex`
- `lib/bullx/ext.ex`
- `native/bullx_ext/Cargo.toml` (add the Cedar Rust dependency to the existing crate)
- `native/bullx_ext/src/lib.rs` (register the `cedar` module with the existing `BullX.Ext` NIF)
- `test/bullx/application_test.exs`
- `test/bullx_accounts/authn_test.exs`
- `test/support/data_case.ex`

### 13.3 Implementation Sequence

1. Add the AuthZ migration, native enum, schemas, changesets, and indexes.
2. Add the `BullX.Config.Accounts` declaration for AuthZ cache TTL.
3. Add `BullXAccounts.AuthZ.Request` normalization and permission-key parsing.
4. Add `BullXAccounts.AuthZ.ResourcePattern` wildcard matching.
5. Add static group membership functions and coarse cache invalidation.
6. Add computed group expression validation and evaluation with cycle detection.
7. Add `BullXAccounts.AuthZ.Cache` as a local ETS owner process.
8. Add the Cedar Rust NIF, `BullX.Ext` shims, and `BullXAccounts.AuthZ.Cedar` wrapper.
9. Add permission grant CRUD with Cedar condition validation.
10. Implement `authorize/4`, `authorize_permission/3`, and `allowed?/4`.
11. Add AuthZ bootstrap for the built-in `admin` group.
12. Add focused tests for schema constraints, group expansion, grants, Cedar failure behavior, caller context, cache invalidation, bootstrap, and AuthN boundary behavior.

## 14. Testing

Tests must prove:

1. AuthZ primary keys use `BullX.Ecto.UUIDv7`.
2. `user_group_type` is a native PostgreSQL enum.
3. Static groups require no `computed_expression`; computed groups require one.
4. `user_group_memberships` has a composite primary key on `{user_id, group_id}`.
5. Group names and group types are immutable after creation.
6. Public group create/update APIs cannot set or clear `built_in`.
7. Public APIs reject static membership writes to computed groups.
8. The `admin` group is bootstrapped idempotently without application-specific grants.
9. The `admin` group cannot be deleted through the public AuthZ API.
10. Public APIs reject deleting a group referenced by a computed expression.
11. Public APIs reject removing the final static member from the built-in `admin` group.
12. Banned users are denied even when direct user grants or group grants exist.
13. Direct user grants authorize matching resource/action requests.
14. Static group grants authorize static members.
15. Computed group grants authorize users whose expression evaluates to true.
16. Computed group cycles return false for the cyclic branch and do not crash authorization.
17. Resource pattern wildcard matching follows this RFC, including `*` matching across `:`, and does not treat patterns as arbitrary regex.
18. Grant writes reject resource patterns containing more than one `*`.
19. Grant writes and authorization requests reject `action` values containing `:`.
20. Actions do not imply other actions.
21. Cedar `true` allows after resource/action matching.
22. Empty conditions are rejected; no matching grant denies.
23. Cedar validation wraps conditions in the exact synthetic `permit(principal, action, resource) when { ... };` policy and rejects condition strings that parse into extra policies, `forbid`, templates, or `unless` clauses.
24. Cedar request input uses `BullXUser`, `BullXAction`, and `BullXResource` entity types, does not expose group names as principal attributes, and does not interpolate resource/action strings into policy source.
25. Cedar `false`, invalid Cedar, Cedar errors, and non-boolean results deny that grant.
26. Caller-provided context is normalized to Cedar-context-compatible string-keyed data and exposed under `context.request`; `nil`, floats, structs, tuples, PIDs, and functions are rejected.
27. Cedar conditions can use precomputed Elixir-side facts passed through caller context.
28. Missing or wrongly typed caller context facts fail closed for that grant without being reported as invalid persisted data.
29. Malformed computed group expressions and unknown `group_member` references are rejected on write and evaluate false if already persisted.
30. Invalid persisted computed group expressions and Cedar conditions emit `[:bullx, :authz, :invalid_persisted_data]`.
31. Permission-key split errors return `{:error, :invalid_request}`.
32. Nil users, malformed user ids, empty resource/action strings, and non-Cedar-context-compatible contexts return `{:error, :invalid_request}`; well-formed missing users return `{:error, :not_found}`; none of these cases raise.
33. Caller-provided resource and action names remain strings and are not converted to atoms.
34. `authorize/3`, `authorize/4`, `authorize_permission/2`, `authorize_permission/3`, `allowed?/3`, `allowed?/4`, and `list_user_groups/1` exist with the documented defaults and effective-group semantics.
35. The default cache TTL is `60_000`, and caching is disabled when `accounts_authz_cache_ttl_ms = 0`.
36. Cache keys include canonical caller context hashes for cached allow/forbidden decisions.
37. Cache TTL expiry is honored.
38. Cache invalidates after group, membership, grant, or user status writes through public APIs.
39. AuthZ bootstrap creates a missing `admin` group when AuthZ tables exist.
40. AuthZ bootstrap never creates admin memberships or application-specific grants.
41. AuthN `/preauth`, provider login, and `/web_auth` behavior remains RFC 0008 behavior.

## 15. Acceptance Criteria

1. `BullXAccounts` exposes AuthZ facade functions while RFC 0008 AuthN remains the owner of identity, login, channel binding, activation, and sessions.
2. AuthZ tables persist groups, static memberships, and permission grants with UUIDv7 primary keys, PostgreSQL-native enum types where applicable, real user/group foreign keys, and the resource/action constraints in this RFC.
3. Built-in `admin` seed data exists without application-specific grants or automatic user membership assignment; AuthZ does not choose administrators.
4. Active users can be authorized through direct, static group, or computed group grants; banned users are always denied; computed group memberships are never persisted as rows.
5. Cedar, caller context, and invalid persisted-data failure behavior follows this RFC: condition strings cannot inject additional policies, failures fail closed per grant, malformed persisted rows are observable, and valid denials are not logged as data corruption.
6. Permission caches are reconstructible, default to a finite local TTL, include canonical caller context in cache keys, and invalidate on public AuthZ/user-status writes.
7. Gateway actor identity remains channel-local; AuthZ never changes the RFC 0008 binding flow.
8. `mix test test/bullx_accounts/authz_test.exs`, `mix test test/bullx_accounts/authz_schema_test.exs`, `mix test test/bullx_accounts/authn_test.exs`, and `mix precommit` pass.
