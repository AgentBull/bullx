# RFC 0009: Feishu Gateway Adapter and Web Login

**Status**: Implementation plan  
**Author**: Boris Ding  
**Created**: 2026-04-24  
**Depends on**: RFC 0002, RFC 0003, RFC 0007, RFC 0008

## 1. Scope

Implement Feishu as a first-class Gateway channel adapter for BullX.

The adapter handles:

- Feishu/Lark inbound events over WebSocket and optional webhook callbacks.
- Feishu card action callbacks.
- Feishu outbound send, edit, and streaming-card delivery through the Gateway delivery contract.
- Feishu-specific `/preauth` and `/web_auth` account linking commands.
- Feishu-specific `/ping` command that directly replies `PONG!` for manual connectivity checks.
- Feishu OIDC web login through BullXWeb and `BullXAccounts.login_from_provider/1`.
- Localized human-facing Feishu replies through `BullX.I18n`.

The adapter uses the existing SDK in `packages/feishu_openapi`. No new dependency is added.

## 2. Non-Goals

- Do not change the Gateway signal contract from RFC 0002.
- Do not change the Gateway delivery or DLQ contract from RFC 0003.
- Do not add a generic OAuth/OIDC framework to `BullXAccounts`.
- Do not persist Feishu access tokens or refresh tokens.
- Do not introduce a separate OTP application.
- Do not make Feishu message media storage a new durable subsystem.
- Do not support marketplace tenant lifecycle management beyond SDK token handling and event normalization.

## 3. Cleanup Plan

### 3.1 What can be deleted

Nothing in the existing Gateway, Accounts, I18n, Web, or SDK implementation should be deleted for this adapter.

The implementation must avoid compatibility shims such as `BullXGateway.Adapters.Feishu` unless an existing caller already requires that module name. The settled subsystem rule places channel adapter implementations in top-level namespaces, so Feishu code belongs under `lib/bullx_feishu/` as `BullXFeishu.*`.

### 3.2 Existing utilities and patterns to reuse

- `BullXGateway.Adapter` behaviour.
- `BullXGateway.AdapterSupervisor` and `BullXGateway.AdapterRegistry`.
- `BullXGateway.publish_inbound/1`.
- `BullXGateway.Inputs.Message`, `MessageEdited`, `MessageRecalled`, `Reaction`, `Action`, `SlashCommand`, and `Trigger`.
- `BullXGateway.Content` blocks and existing validation.
- `BullXGateway.Delivery`, `BullXGateway.deliver/1`, ScopeWorker serialization, DLQ, and telemetry.
- `BullXAccounts.resolve_channel_actor/3`, `match_or_create_from_channel/1`, `consume_activation_code/2`, `issue_user_channel_auth_code/3`, and `login_from_provider/1`.
- `BullX.I18n.t/3` and locale TOML files.
- `BullXWeb` session helpers from RFC 0008.
- `FeishuOpenAPI.Client`, `Auth`, `Event`, `Event.Dispatcher`, `CardAction`, `CardAction.Handler`, and `WS.Client`.

### 3.3 Code paths changing

- Add a new top-level channel adapter namespace: `BullXFeishu.*`.
- Add BullXWeb routes and a thin Feishu login controller for OIDC browser login.
- Add Feishu translation keys to `priv/locales/en-US.toml` and `priv/locales/zh-Hans-CN.toml`.
- Add Feishu adapter configuration examples without changing Gateway core configuration shape.

### 3.4 Invariants

- The Gateway core remains transport-agnostic.
- Feishu actor identities remain channel-local until `BullXAccounts` resolves or links them.
- Adapter process state is ephemeral and reconstructible; PostgreSQL remains the system of record for accounts and Gateway control-plane data.
- Inbound events are acknowledged only after successful publish, duplicate detection, or intentional adapter-local command handling.
- Human-facing Feishu text is localized through `BullX.I18n`; adapter modules must not hard-code operator/user messages.
- Feishu human-facing text uses BullX's application-global locale from `BullX.Config.I18n.i18n_default_locale!/0`; the adapter does not read Feishu tenant locale, user locale, `Accept-Language`, or profile language fields.
- Outbound delivery preserves per-scope serialization through RFC 0003 ScopeWorkers.
- Adapter success paths return only `{:ok, %BullXGateway.Delivery.Outcome{status: :sent | :degraded, error: nil}}`. Adapter failures return `{:error, error_map}`. The adapter must never return `{:ok, %Outcome{status: :failed}}`.
- Adapter error maps are JSON-neutral string-keyed maps. `error["kind"]` is a string and optional retry hints live under `error["details"]`.
- Feishu `:stream` DLQ replay with absent stream content returns `{:error, %{"kind" => "payload", ...}}`.
- No Feishu user token is persisted by the first implementation.
- Manual local runs must be observable from normal logs: startup/connection, inbound mapping, direct-command handling, publish result, and delivery enqueue/failure all emit structured log lines with safe metadata.

### 3.5 Verification command

Run:

```bash
mix test test/bullx_feishu test/bullx_web/controllers/feishu_auth_controller_test.exs test/bullx_accounts/authn_test.exs
mix precommit
```

## 4. Subsystem Placement

Feishu is a Gateway channel adapter, not a new BullX subsystem. It is implemented in a top-level namespace because channel adapters are first-class integrations parallel to the Gateway core implementation.

Files live under:

```text
lib/bullx_feishu/
test/bullx_feishu/
```

The public adapter module is:

```elixir
BullXFeishu.Adapter
```

It implements `BullXGateway.Adapter` and is configured as:

```elixir
{{:feishu, "default"}, BullXFeishu.Adapter, config}
```

Only the browser login callback touches `BullXWeb`, because web login must use Phoenix cookie sessions.

## 5. Module Plan

### 5.1 Adapter Modules

Create:

```text
lib/bullx_feishu.ex
lib/bullx_feishu/adapter.ex
lib/bullx_feishu/channel.ex
lib/bullx_feishu/config.ex
lib/bullx_feishu/cache.ex
lib/bullx_feishu/event_listener.ex
lib/bullx_feishu/webhook_plug.ex
lib/bullx_feishu/event_mapper.ex
lib/bullx_feishu/content_mapper.ex
lib/bullx_feishu/direct_command.ex
lib/bullx_feishu/delivery.ex
lib/bullx_feishu/streaming_card.ex
lib/bullx_feishu/sso.ex
lib/bullx_feishu/error.ex
```

`BullXFeishu.Cache` owns the adapter-local TTL KV needs: message context, card action dedupe, and direct-command result dedupe. They are separate tables or key prefixes under one module, not three pieces of infrastructure.

`BullXFeishu.EventMapper` owns Feishu event normalization, profile extraction/resolution, and the early self-sent bot message filter.

`BullXFeishu.EventListener` owns the small account-gate call before publishing. A separate account-gate module is not needed.

`BullXFeishu.WebhookPlug` handles both event callbacks and card action callbacks by path. It must preserve raw request bytes before JSON parsing so SDK verification receives the exact signed body.

`BullXFeishu.StreamingCard` remains separate because it has real state: card ID, message ID, accumulated text, sequence numbers, throttling, and finalization.

There is no `BullXFeishu.API` wrapper in the first implementation. Adapter modules call `FeishuOpenAPI.get/3`, `post/3`, `patch/3`, `upload/3`, and `download/3` directly, with `BullXFeishu.Error` handling error normalization. Tests use the SDK's Req-based test support and local fake clients where needed.

### 5.2 Web Modules

Create:

```text
lib/bullx_web/controllers/feishu_auth_controller.ex
test/bullx_web/controllers/feishu_auth_controller_test.exs
```

Modify:

```text
lib/bullx_web/router.ex
```

The controller remains thin. Feishu URL construction, token exchange, userinfo fetching, and profile normalization live in `BullXFeishu.SSO`.

### 5.3 Locale Files

Modify:

```text
priv/locales/en-US.toml
priv/locales/zh-Hans-CN.toml
```

Add keys under `gateway.feishu.*`.

## 6. Configuration

Feishu adapter configuration is passed through the RFC 0002 Gateway adapter spec.

Example:

```elixir
config :bullx, :gateway,
  adapters: [
    {{:feishu, "default"}, BullXFeishu.Adapter,
     %{
       app_id: {:system, "BULLX_FEISHU_APP_ID"},
       app_secret: {:system, "BULLX_FEISHU_APP_SECRET"},
       domain: :feishu,
       app_type: :self_built,
       connection_mode: :websocket,
       verification_token: {:system, "BULLX_FEISHU_VERIFICATION_TOKEN"},
       encrypt_key: {:system, "BULLX_FEISHU_ENCRYPT_KEY"},
       bot_open_id: {:system, "BULLX_FEISHU_BOT_OPEN_ID"},
       dedupe_ttl_ms: :timer.minutes(5),
       message_context_ttl_ms: :timer.hours(24) * 30,
       card_action_dedupe_ttl_ms: :timer.minutes(15),
       inline_media_max_bytes: 524_288,
       stream_update_interval_ms: 100,
       sso: %{
         enabled: true,
         redirect_uri: {:system, "BULLX_FEISHU_SSO_REDIRECT_URI"},
         scopes: ["openid", "profile", "email", "phone"]
       }
     }}
  ]
```

Required keys:

- `:app_id`
- `:app_secret`

Recommended keys:

- `:verification_token`
- `:encrypt_key`
- `:bot_open_id`
- `:sso.redirect_uri` when web login is enabled

Optional keys:

- `:domain`: `:feishu` or `:lark`, default `:feishu`.
- `:app_type`: `:self_built` or `:marketplace`, default `:self_built`.
- `:connection_mode`: `:websocket` or `:webhook`, default `:websocket`.
- `:webhook`: `%{scheme:, host:, port:, event_path:, card_action_path:}` for adapter-owned webhook listeners.
- `:dedupe_ttl_ms`: read by Gateway through `AdapterRegistry` after the adapter config is registered; default `5 minutes`.
- `:message_context_ttl_ms`: adapter-local recall/reaction context cache, default `30 days`.
- `:card_action_dedupe_ttl_ms`: adapter-local card action dedupe, default `15 minutes`.
- `:inline_media_max_bytes`: maximum media bytes embedded as a `data:` URI, default `512 KiB`.
- `:stream_update_interval_ms`: streaming card throttle interval, default `100 ms`.
- `:status_reactions`: optional best-effort reaction UX config, default `%{enabled: true, in_progress: "Typing", failure: "CrossMark"}`.

Configuration resolution must use the existing BullX config style, including system env indirection. Secrets must not be logged.

## 7. Supervision and Runtime Shape

`BullXFeishu.Adapter.child_specs/2` returns channel-scoped children. The Gateway core remains unchanged.

For WebSocket mode:

```text
BullXGateway.AdapterSupervisor.Channel
└── BullXFeishu.Channel
└── FeishuOpenAPI.WS.Client
```

For webhook mode:

```text
BullXGateway.AdapterSupervisor.Channel
└── BullXFeishu.Channel
└── Bandit/Plug listener using BullXFeishu.WebhookPlug
```

`BullXFeishu.Channel` owns:

- The normalized channel config.
- The SDK client.
- The event dispatcher and card action handler.
- Adapter-local cache tables through `BullXFeishu.Cache`.

The caches are process-local and reconstructible. If the channel restarts, missing recall/reaction context is recovered by calling Feishu APIs when possible; otherwise the inbound event is published with the available Feishu IDs and a localized or structured fallback.

The cache responsibilities are deliberately narrow:

- Message context cache is correlation context, not dedupe. It helps recall and reaction events recover chat/message/sender metadata.
- Card action dedupe protects adapter-local side effects that happen before `publish_inbound/1`, such as account gate checks.
- Direct command result dedupe is needed because `/preauth` and `/web_auth` are intentionally not published through Gateway inbound dedupe.

No failure boundary changes outside the adapter channel supervisor.

## 8. Manual Run Support

This RFC does not require a live automated test suite. It does require the implementation to be manually runnable with normal development startup and normal logs.

### 8.1 Startup and Connection Logs

The adapter must emit structured `Logger` lines that let an operator confirm the Feishu channel is alive without attaching a debugger.

At `info` level:

- channel start requested: `channel`, `channel_id`, `connection_mode`, `domain`, `app_type`
- channel registered in `BullXGateway.AdapterRegistry`
- WebSocket mode: connecting, connected, reconnecting, disconnected
- webhook mode: listener started, host, port, event path, card action path
- event handlers registered: event type list
- bot identity resolved: source `configured` or `api`, with `bot_open_id` / `bot_user_id` when available

At `warning` level:

- bot identity cannot be resolved
- Feishu app credentials are missing or rejected
- WebSocket fatal close / reconnect exhaustion
- webhook signature/decryption failure
- account gate returns `:activation_required` or `:user_banned`

Secrets, tokens, OAuth codes, raw webhook bodies, and raw message bodies must not be logged.

### 8.2 Inbound and Delivery Logs

For every Feishu event that reaches mapping, log one safe inbound line with:

- `channel`
- `channel_id`
- `event_type`
- `event_id`
- `scope_id`
- `external_message_id` when present
- `actor_id` when present
- `chat_type` when present

For every terminal inbound decision, log one safe result line:

- ignored self-sent bot message
- direct command handled
- account activation required
- account denied
- published
- duplicate
- publish failed

For direct commands that enqueue an outbound `Delivery`, log:

- `command_name`
- `delivery_id`
- `scope_id`
- `reply_to_external_id`
- enqueue result

These logs are part of the manual-run contract. Telemetry remains the structured metrics/tracing surface; logs are the operator-facing way to see that a local run is wired correctly.

`/ping` is the built-in manual connectivity command. It must work before account activation, so an operator can verify Feishu inbound and outbound wiring before using `/preauth`.

### 8.3 Bootstrap Activation Code

Feishu does not create bootstrap activation codes. Manual first-user activation relies on the existing `BullXAccounts.Bootstrap` startup worker. On an empty deployment with no valid activation code, that worker creates one code and logs:

```text
BullX bootstrap activation code: <code>
```

The Feishu adapter only consumes that code through `/preauth <code>`.

## 9. SDK Usage

Use `FeishuOpenAPI.Client.new/3` to construct the SDK client:

```elixir
FeishuOpenAPI.Client.new(app_id, app_secret, domain: domain, app_type: app_type)
```

Use:

- `FeishuOpenAPI.Event.verify_and_decode/3` for webhook URL verification, signature verification, decryption, and event decoding.
- `FeishuOpenAPI.Event.Dispatcher` for WebSocket and webhook event routing.
- `FeishuOpenAPI.CardAction.Handler` for interactive card callbacks.
- `FeishuOpenAPI.WS.Client` for long-lived event transport.
- `FeishuOpenAPI.Auth.user_access_token/3` for OIDC token exchange.
- `FeishuOpenAPI.get/3`, `post/3`, `patch/3`, `upload/3`, and `download/3` for message send/edit, message resource download, card creation, card content streaming, card settings finalization, media upload, and userinfo retrieval.

The adapter must not reimplement SDK-level signature verification, token caching, envelope decoding, or WebSocket frame handling.

The SDK intentionally pre-bakes only auth and transport helpers. Feishu business endpoints that do not have named SDK helpers are called through the generic request functions above.

## 10. Inbound Event Mapping

Every user-origin Feishu event is normalized to one of the RFC 0002 `BullXGateway.Inputs.*` structs, then submitted through `BullXGateway.publish_inbound/1`.

### 10.1 Common Envelope

All Feishu inbound signals use:

```elixir
channel = {:feishu, channel_id}
source = "bullx://gateway/feishu/#{channel_id}"
```

Event IDs use Feishu's event ID whenever present. If Feishu does not provide a stable event ID for an event type, derive one from immutable Feishu fields.

Common refs:

```elixir
refs: %{
  "feishu" => %{
    "tenant_key" => tenant_key,
    "app_id" => app_id,
    "event_type" => event_type,
    "event_id" => event_id,
    "message_id" => message_id,
    "open_message_id" => open_message_id,
    "chat_id" => chat_id,
    "chat_type" => chat_type
  }
}
```

Unknown or absent fields are omitted, not set to `nil`.

### 10.2 Actor Identity

The first `EventMapper` step for message-like events is self-sent bot filtering. If Feishu reports `sender_type` as `bot` or `app` and the sender matches configured or resolved `bot_open_id` / `bot_user_id`, the event is ignored before content parsing, account gating, direct-command handling, or publishing. This prevents outbound Feishu card updates and bot-authored messages from re-entering BullX as user input.

The Gateway actor ID is channel-local:

```text
feishu:<open_id>
```

`open_id` is the required primary binding identity for user-origin events. If a callback supplies only `user_id` or `union_id`, the adapter must try to resolve `open_id` through Feishu before publishing. If no `open_id` can be resolved, the event is rejected with a telemetry event and no account binding is created.

Profile data may include:

```elixir
%{
  "display_name" => name,
  "avatar_url" => avatar_url,
  "email" => email,
  "phone" => mobile,
  "open_id" => open_id,
  "union_id" => union_id,
  "user_id" => user_id,
  "tenant_key" => tenant_key
}
```

The same `external_id = "feishu:#{open_id}"` is used by IM events, card actions, `/preauth`, `/web_auth`, and Feishu web login.

Phone profile fields are normalized before they are passed to `BullXAccounts`. The adapter calls `BullX.Ext.phone_normalize_e164/1` on candidate phone strings and keeps only a canonical E.164 value. If Feishu returns an ambiguous or malformed phone number, the adapter omits `"phone"` from the profile instead of passing a raw value. For mainland Feishu tenants, the adapter may try a `+86` candidate for an 11-digit mobile number before dropping it; invalid candidates are still discarded.

### 10.3 Chat Type Semantics

Feishu `chat_type` remains adapter metadata, not a Gateway core concept. The adapter still uses it for Feishu-specific behavior:

- `p2p` chats may run `/preauth` and `/web_auth`.
- group chats publish normal user messages when account gating succeeds, but direct account-linking commands are rejected with a localized instruction to DM the bot.
- group activation prompts must not echo activation codes or web-auth codes.

### 10.4 Message Received

Feishu `im.message.receive_v1` maps to `BullXGateway.Inputs.Message`.

Important fields:

- `id`: Feishu event ID, or `message.message_id`.
- `scope_id`: Feishu `chat_id`.
- `thread_id`: Feishu `thread_id` when present.
- `reply_to_external_id`: Feishu parent or upper message ID when present.
- `external_message_id`: Feishu message ID.
- `actor`: normalized sender actor.
- `content`: normalized Gateway content blocks.

The adapter stores message context for recall/reaction/card-action correlation:

```elixir
%{
  message_id: message_id,
  open_message_id: open_message_id,
  chat_id: chat_id,
  chat_type: chat_type,
  sender_open_id: open_id,
  parent_message_id: parent_message_id,
  created_at: created_at
}
```

The cache TTL defaults to 30 days.

### 10.5 Slash Commands

Text messages whose normalized text starts with `/` are parsed as slash commands.

Adapter-local commands:

- `/ping`
- `/preauth <code>`
- `/web_auth`

These commands are handled by `BullXFeishu.DirectCommand` and are not published to Runtime. They still go through Feishu transport verification and direct-command dedupe. `/preauth` and `/web_auth` also require account profile normalization; `/ping` only requires enough message context to reply to the same Feishu chat/message.

Direct account-linking commands are valid only in Feishu `p2p` chats. In a group chat, the adapter sends a localized "message the bot privately" reply or best-effort DM and does not consume the activation code, issue a web-auth code, or publish the command.

Other slash commands are published as `BullXGateway.Inputs.SlashCommand`.

### 10.6 Message Edited

Feishu message update events map to `BullXGateway.Inputs.MessageEdited`.

The derived ID is:

```text
im.message.updated_v1:<message_id>:<update_time_or_event_id>
```

The input includes:

- `target_external_message_id`
- updated normalized content
- same `scope_id` and actor rules as `Message`

### 10.7 Message Recalled

Feishu `im.message.recalled_v1` maps to `BullXGateway.Inputs.MessageRecalled`.

If Feishu does not supply an event ID, derive:

```text
im.message.recalled_v1:<message_id>:<recall_time>
```

The adapter uses the message context cache or Feishu message APIs to resolve:

- original `chat_id`
- original sender
- parent message ID

If the original context cannot be recovered, publish the recall with the target message ID and available actor data instead of inventing missing values.

### 10.8 Reactions

Feishu `im.message.reaction.created_v1` and `im.message.reaction.deleted_v1` map to `BullXGateway.Inputs.Reaction`.

If Feishu does not supply an event ID, derive:

```text
<event_type>:<message_id>:<actor_open_id>:<emoji>:<action_time>
```

The action is:

- `:added` for created reactions.
- `:removed` for deleted reactions.

The adapter must preserve Feishu's raw emoji/reaction type in refs.

### 10.9 Card Actions

Feishu interactive card callbacks map to `BullXGateway.Inputs.Action`.

The stable action ID is:

```text
card_action:<open_message_id>:<action_tag>:<actor_open_id>
```

If Feishu supplies a callback token or request UUID, include it in refs and use it for adapter-local dedupe.

The input includes:

- `target_external_message_id`: Feishu `open_message_id`.
- `scope_id`: Feishu `open_chat_id` when present.
- `action_id`: Feishu action tag.
- `values`: callback values from the card action payload.
- `actor`: normalized operator actor using the operator `open_id` as `external_id = "feishu:#{open_id}"`.

Card action callbacks are deduped for 15 minutes by default before account gating or publishing.

### 10.10 Lifecycle and App Ticket Events

Feishu SDK-level app ticket events are consumed by SDK/token handling and are not published as Gateway inputs.

Bot lifecycle events are ignored by default. If later product requirements need lifecycle handling, add an explicit adapter option that emits `BullXGateway.Inputs.Trigger`. Do not publish lifecycle events implicitly in the first implementation.

## 11. Content Mapping

`BullXFeishu.ContentMapper` converts Feishu message content into RFC 0002 `BullXGateway.Content` blocks.

### 11.1 Text

Feishu `text` and rich `post` text map to:

```elixir
%BullXGateway.Content{kind: :text, body: %{"text" => text}}
```

Mentions are stripped from the primary text when Feishu marks them as bot mentions, but raw mention metadata remains in refs.

### 11.2 Images and Files

For Feishu image, audio, video, and file resources:

1. Try to download the resource with the SDK.
2. If the resource is below `inline_media_max_bytes`, emit a `data:` URI content block.
3. If the resource is too large or cannot be downloaded, emit a `feishu://message-resource/...` URI with `fallback_text` and raw resource IDs in refs.

No local filesystem path is exposed in Gateway signals.

Examples:

```elixir
%BullXGateway.Content{
  kind: :image,
  body: %{
    "url" => "data:image/png;base64,...",
    "fallback_text" => "[image]"
  }
}
```

```elixir
%BullXGateway.Content{
  kind: :file,
  body: %{
    "url" => "feishu://message-resource/<message_id>/<file_key>",
    "filename" => filename,
    "fallback_text" => filename || "[file]"
  }
}
```

### 11.3 Interactive Cards

Inbound Feishu interactive card messages map to:

```elixir
%BullXGateway.Content{
  kind: :card,
  body: %{
    "format" => "feishu.card",
    "fallback_text" => fallback_text,
    "payload" => sanitized_card_json
  }
}
```

If the card JSON is too large or includes unsupported values, keep only `format`, `fallback_text`, and Feishu refs.

### 11.4 Sticker, Emotion, and Emoji Messages

Feishu sticker, emotion, and emoji-only messages map to text fallback content. The adapter must not silently drop them as empty content.

Examples:

```elixir
%BullXGateway.Content{kind: :text, body: %{"text" => ":thumbsup:"}}
```

```elixir
%BullXGateway.Content{kind: :text, body: %{"text" => "[sticker]"}}
```

## 12. Account Gate

Before publishing user-origin inputs, the adapter calls:

```elixir
BullXAccounts.match_or_create_from_channel(channel_input)
```

The channel input uses:

```elixir
%{
  adapter: :feishu,
  channel_id: channel_id,
  external_id: "feishu:#{open_id}",
  profile: profile,
  metadata: %{
    "source" => "feishu_im",
    "tenant_key" => tenant_key,
    "chat_id" => chat_id,
    "chat_type" => chat_type
  }
}
```

Outcomes:

- `{:ok, _user, _binding}`: publish the Gateway input.
- `{:error, :activation_required}`: send a localized activation-required reply and do not publish.
- `{:error, :user_banned}`: send a localized denied reply when configured to do so and do not publish.
- Other errors: return a transport error so the event is not acknowledged.

In group chats, activation-required replies must not include an activation code or web-auth code. They should direct the user to message the bot privately. In `p2p` chats, the adapter may include the normal localized `/preauth` guidance.

The resolved BullX user ID is not injected into the Gateway signal. Runtime and Brain continue to receive channel-local Gateway actor data unless a later contract explicitly changes that.

## 13. Direct Commands

### 13.1 `/ping`

`/ping` is a built-in adapter-local connectivity command. It exists to make manual local runs observable before account activation or Runtime handling is wired.

Flow:

1. Accept the command in both `p2p` and group chats.
2. Run transport verification, self-sent bot filtering, command parsing, actor extraction when available, and direct-command dedupe.
3. Do not call `BullXAccounts.match_or_create_from_channel/1`.
4. Do not publish a `SlashCommand` to Runtime.
5. Build a `BullXGateway.Delivery` with:
   - `op: :send`
   - `channel: {:feishu, channel_id}`
   - `scope_id: chat_id`
   - `reply_to_external_id: message_id`
   - `content: %BullXGateway.Delivery.Content{kind: :text, body: %{"text" => BullX.I18n.t("gateway.feishu.ping.pong")}}`
   - `extensions: %{"feishu" => %{"direct_command" => "ping", "event_id" => event_id}}`
6. Call `BullXGateway.deliver/1`.
7. Acknowledge the Feishu event after the delivery is accepted by Gateway (`{:ok, delivery_id}`) or after a duplicate direct-command result is found.

The rendered response text is `PONG!` in both bundled locales.

### 13.2 `/preauth <code>`

`/preauth <code>` links a Feishu channel actor to an existing activation code.

Flow:

1. Reject group chats with a localized DM-only instruction. Do not consume the code.
2. Normalize Feishu actor and trusted profile.
3. Build the same channel input used by regular messages.
4. Call `BullXAccounts.consume_activation_code(code, channel_input)`.
5. Send one localized Feishu reply.
6. Do not publish the command to Runtime.

Result mapping:

| Account result | Feishu reply key |
|---|---|
| `{:ok, _user, _binding}` | `gateway.feishu.auth.activation_success` |
| `{:error, :invalid_or_expired_code}` | `gateway.feishu.auth.activation_code_invalid` |
| `{:error, :already_bound}` | `gateway.feishu.auth.already_linked` |
| `{:error, :user_banned}` | `gateway.feishu.auth.denied` |
| any other `{:error, _}` | `gateway.feishu.auth.activation_failed` |

The direct command result cache stores the reply result by Feishu event ID for 5 minutes to avoid duplicate replies during transport retries.

### 13.3 `/web_auth`

`/web_auth` issues a short-lived account-linking code and sends a localized message with the code and web login link.

Flow:

1. Reject group chats with a localized DM-only instruction. Do not issue a web-auth code.
2. Normalize Feishu actor and trusted profile.
3. Call `BullXAccounts.issue_user_channel_auth_code(:feishu, channel_id, "feishu:#{open_id}")`.
4. Render the localized message through `BullX.I18n`.
5. Send it with Feishu delivery APIs.
6. Do not publish the command to Runtime.

Result mapping:

| Account result | Feishu reply key |
|---|---|
| `{:ok, code}` | `gateway.feishu.auth.web_auth_created` |
| `{:error, :not_bound}` | `gateway.feishu.auth.web_auth_not_bound` |
| `{:error, :user_banned}` | `gateway.feishu.auth.denied` |
| any other `{:error, _}` | `gateway.feishu.auth.web_auth_failed` |

If the actor is already linked and active, `issue_user_channel_auth_code/3` returns a code for that linked user. If the actor is unbound, the adapter uses the localized not-bound reply instead of creating a web session path.

## 14. Feishu Web Login

Feishu web login integrates RFC 0008 without adding generic provider machinery to Accounts.

### 14.1 Routes

Add routes under the browser pipeline:

```elixir
get "/sessions/feishu", FeishuAuthController, :new
get "/sessions/feishu/callback", FeishuAuthController, :callback
```

The route accepts:

- `channel_id`: defaults to `"default"`.
- `return_to`: optional local path.

Only standard OIDC authorization-code login is enabled in the first implementation. QR login and an `auth_mode` configuration option are deferred until BullX supports a second Feishu web-login mode.

### 14.2 Authorization Request

`BullXFeishu.SSO.authorization_url/2` builds the Feishu authorization URL from:

- configured domain
- app ID
- redirect URI
- scopes
- signed state

State is signed with Phoenix token infrastructure and includes:

```elixir
%{
  "provider" => "feishu",
  "channel_id" => channel_id,
  "return_to" => return_to,
  "issued_at" => unix_seconds,
  "nonce" => random_nonce
}
```

State lifetime defaults to 10 minutes.

### 14.3 Callback

The callback flow is:

1. Verify signed state and local `return_to`.
2. Exchange `code` with `FeishuOpenAPI.Auth.user_access_token/3`.
3. Fetch OIDC userinfo with `FeishuOpenAPI.get(client, "/open-apis/authen/v1/user_info", user_access_token: access_token)`.
4. Normalize provider identity:

   ```elixir
   %{
     provider: :feishu,
     provider_user_id: open_id,
     external_id: "feishu:#{open_id}",
     profile: %{
       "display_name" => display_name,
       "email" => email,
       "phone" => phone,
       "avatar_url" => avatar_url,
       "open_id" => open_id,
       "union_id" => union_id,
       "user_id" => user_id,
       "tenant_key" => tenant_key
     },
     metadata: %{
       "channel_id" => channel_id,
       "domain" => domain
     }
   }
   ```

   `open_id` is required. The SSO profile uses the same `external_id = "feishu:#{open_id}"` as IM events and card actions. Phone fields follow the same E.164 normalization/drop rule as inbound profiles.

5. Call `BullXAccounts.login_from_provider/1`.
6. On success, renew the Phoenix session and store the BullX user session exactly as RFC 0008 does for other logins.
7. On `{:error, :not_bound}`, show the existing login surface with a localized error that directs the user to activate from Feishu with `/preauth`.
8. On `{:error, :user_banned}`, fail closed with the localized denied login response.

The first implementation discards Feishu access and refresh tokens after userinfo retrieval.

## 15. Outbound Delivery Mapping

`BullXFeishu.Adapter.deliver/2` handles `:send` and `:edit`.

`BullXFeishu.Adapter.stream/3` handles `:stream`.

### 15.1 Send

Targeting rules:

- `delivery.scope_id` is Feishu `chat_id`.
- `delivery.thread_id` is passed when Feishu thread APIs support it.
- `delivery.reply_to_external_id` sends a Feishu reply.
- Otherwise, send a message to `scope_id`.

Idempotency:

- Use `delivery.id` as the Feishu `uuid` request parameter for `im/v1/messages` create/reply calls.
- Preserve Feishu response IDs in `primary_external_id`.

Content rules:

- `:text`: send Feishu text or post content.
- `:card` with `format = "feishu.card"` or `"feishu.card.v2"`: send Feishu interactive card.
- `:image`: upload and send native image when the content URI is `data:`, `file:`, or HTTP(S) and the adapter can read it; otherwise degrade to fallback text.
- `:file`, `:audio`, `:video`: upload and send native file/media when possible; otherwise degrade to fallback text.
- Unsupported multi-block combinations are degraded to a single localized/fallback text message.

If a reply send fails because Feishu reports the target message was withdrawn or missing, specifically codes `230011` or `231003`, the adapter retries once as a normal chat send to `delivery.scope_id`. A successful fallback returns `status: :degraded` with a warning such as `"reply_target_missing_sent_to_scope"`. If `scope_id` is absent, return `%{"kind" => "payload"}`.

Degradation returns:

```elixir
{:ok,
 %BullXGateway.Adapter.DeliveryOutcome{
   status: :degraded,
   primary_external_id: message_id,
   warnings: [...]
 }}
```

### 15.2 Edit

`delivery.target_external_id` is required for edit.

Supported edits:

- Text/post message content.
- Interactive card content.

Unsupported edit content returns a `:payload` error. If Feishu reports that the target message no longer exists or cannot be edited, map that to a non-retryable `:payload` or `:unsupported` error, not a network error.

### 15.3 Stream

Feishu streaming uses CardKit:

If `stream/3` receives absent stream content, including a DLQ replay rebuilt with `delivery.content == nil`, it returns:

```elixir
{:error, %{"kind" => "payload", "message" => "stream content is not replayable"}}
```

No placeholder card is created for this case.

1. Create a Feishu card with a single streaming text element whose element ID is `content`.
2. Send the card as a new message or reply.
3. Consume stream chunks.
4. Update `cardElement.content` with increasing sequence numbers and UUIDs.
5. Throttle updates by `stream_update_interval_ms`.
6. Finalize card settings with `streaming_mode: false`.
7. Return the final message ID and card ID in the delivery outcome.

Chunks may be:

- `binary()`: append text.
- `%{text: binary()}`: append text.
- `%{"text" => binary()}`: append text.
- `%{replace_text: binary()}` or `%{"replace_text" => binary()}`: replace accumulated text.

The summary is finalized once, at close, using the first 80 visible characters of the final text. Per-chunk updates patch only `cardElement.content`; they do not need to synchronize `summary`.

When `status_reactions.enabled` is true and `reply_to_external_id` is present, the adapter sends a best-effort Feishu reaction before streaming starts:

- start: add `Typing`
- success: remove the in-progress reaction when Feishu returns a reaction ID that can be removed
- failure/cancel: replace the in-progress reaction with `CrossMark`

Reaction failures are warnings only. They must not turn a successful stream into a failed delivery.

On stream error or cancellation, the adapter attempts one final card update with localized failure text and then returns the original error to the Gateway delivery pipeline.

## 16. Error Mapping

`BullXFeishu.Error` maps SDK and Feishu API errors into RFC 0003 adapter error maps.

The returned map must be JSON-neutral and string-keyed:

```elixir
%{
  "kind" => "rate_limit",
  "message" => "Feishu API rate limited",
  "details" => %{
    "retry_after_ms" => 3000,
    "code" => 99_991_400,
    "log_id" => "..."
  }
}
```

Mapping rules:

- HTTP 429 or Feishu rate-limit codes -> `%{"kind" => "rate_limit", "details" => %{"retry_after_ms" => ...}}`.
- HTTP 401/403 or token/app credential errors -> `%{"kind" => "auth"}`.
- Timeout, DNS, TLS, WebSocket disconnect, and temporary transport failures -> `%{"kind" => "network"}`.
- Invalid message body, unsupported content, missing required Feishu target, uneditable message, or replayed stream with no enumerable -> `%{"kind" => "payload"}`.
- Unsupported Feishu operation or content type with no valid fallback -> `%{"kind" => "unsupported"}`.
- Stream cancellation observed by the adapter -> `%{"kind" => "stream_cancelled"}`.
- Unknown Feishu API errors -> `%{"kind" => "unknown"}` with sanitized code, message, and log ID.

Adapters do not emit `"contract"` or `"adapter_restarted"`; those are Gateway-owned failure kinds.

The SDK's retry behavior remains the first line of transient retry. Gateway ScopeWorker and DLQ remain responsible for durable retry and operator recovery.

## 17. Telemetry

Emit adapter telemetry under:

```text
[:bullx, :feishu, :event, :received]
[:bullx, :feishu, :event, :mapped]
[:bullx, :feishu, :event, :ignored]
[:bullx, :feishu, :event, :publish, :start]
[:bullx, :feishu, :event, :publish, :stop]
[:bullx, :feishu, :event, :publish, :exception]
[:bullx, :feishu, :direct_command, :handled]
[:bullx, :feishu, :delivery, :start]
[:bullx, :feishu, :delivery, :stop]
[:bullx, :feishu, :delivery, :exception]
[:bullx, :feishu, :sso, :callback]
```

Metadata must include:

- `channel`
- `channel_id`
- `event_type` when known
- `delivery_id` for outbound delivery
- sanitized Feishu API code/log ID when present

Metadata must not include app secrets, access tokens, refresh tokens, raw message bodies, or OAuth codes.

## 18. I18n Keys

Feishu adapter text is rendered with BullX's application-global locale. The adapter does not choose a locale from Feishu tenant/user profile data.

Add at least these keys in both supported locales:

```toml
[gateway.feishu.auth]
activation_required = "..."
activation_success = "..."
activation_code_invalid = "..."
activation_failed = "..."
already_linked = "..."
web_auth_created = "..."
web_auth_not_bound = "..."
web_auth_failed = "..."
login_not_bound = "..."
denied = "..."
direct_command_dm_only = "..."

[gateway.feishu.ping]
pong = "PONG!"

[gateway.feishu.delivery]
fallback_text = "..."
stream_generating = "..."
stream_failed = "..."
stream_cancelled = "..."
reply_target_missing_sent_to_scope = "..."

[gateway.feishu.errors]
unsupported_message = "..."
profile_unavailable = "..."
```

Tests must fail if any adapter-used key is missing in either locale.

## 19. Security

- Verify Feishu webhook signatures and encrypted payloads through `FeishuOpenAPI.Event.verify_and_decode/3`.
- Verify card action callbacks through `FeishuOpenAPI.CardAction.Handler`.
- Preserve webhook raw body bytes before JSON parsing. `BullXFeishu.WebhookPlug` must run before any body-consuming parser or use `Plug.Parsers, body_reader: {BullXGateway.Webhook.RawBodyReader, :read_body, []}` and read `conn.assigns.raw_body` for SDK verification.
- Reject unsigned webhook requests when verification config is present.
- Enforce a webhook max body size, default `1 MB`.
- Do not log raw webhook bodies, OAuth codes, access tokens, refresh tokens, app secrets, or decrypted callback payloads.
- Validate OAuth state and redirect only to local paths.
- Discard Feishu user tokens after profile retrieval.
- Drop self-sent bot messages at the start of event mapping using configured or resolved bot identity.
- Treat `/preauth` and `/web_auth` as `p2p`-only commands. Group messages containing those commands never consume or issue secrets.
- Keep Gateway actor IDs channel-local; do not expose BullX user IDs in Gateway signals.

## 20. Testing Plan

### 20.1 Unit Tests

Add tests under `test/bullx_feishu/` for:

- Config normalization and secret redaction.
- SDK generic request usage for userinfo, message APIs, CardKit, upload, and download.
- WebSocket event mapping for:
  - message received
  - slash command
  - message edited
  - message recalled
  - reaction created
  - reaction deleted
  - card action callback
- Content mapping for text, post, image, file, audio/video fallback, and interactive cards.
- Actor/profile normalization with `open_id`, `union_id`, `user_id`, email, phone, and tenant key.
- E.164 phone normalization and invalid phone omission.
- Early self-sent bot message filtering.
- Account gate outcomes.
- `/ping` direct command bypasses account gate, enqueues a Gateway Delivery, and renders `PONG!`.
- `/preauth` direct command, including `:invalid_or_expired_code`, `:already_bound`, and `:user_banned`.
- `/web_auth` direct command using `issue_user_channel_auth_code/3`.
- Group-chat rejection for `/preauth` and `/web_auth`.
- Delivery send/edit degradation.
- Reply fallback for Feishu codes `230011` and `231003`.
- Adapter error maps with string keys and string `kind`.
- Streaming card sequence/finalization behavior.
- Stream replay with nil content returns `%{"kind" => "payload"}`.
- Error mapping.
- Missing locale key checks.

### 20.2 Integration Tests

Use fake SDK clients or Req test stubs. Do not call Feishu network endpoints in tests.

Cover:

- `BullXFeishu.Adapter.child_specs/2` in WebSocket mode.
- Webhook challenge handling.
- Webhook raw body preservation for SDK signature verification.
- Webhook signature/decryption dispatch through SDK fixtures.
- Card action callback dispatch through SDK fixtures.
- `BullXGateway.publish_inbound/1` path with a Feishu message.
- `BullXGateway.deliver/1` send/edit paths with fake Feishu SDK responses.
- DLQ write on non-retryable and exhausted retry cases.
- Feishu SSO controller callback into `BullXAccounts.login_from_provider/1`.

### 20.3 Commands

Run:

```bash
mix test test/bullx_feishu
mix test test/bullx_web/controllers/feishu_auth_controller_test.exs
mix test test/bullx_accounts/authn_test.exs
mix precommit
```

## 21. Acceptance Criteria

1. `BullXFeishu.Adapter` implements `BullXGateway.Adapter`.
2. A configured Feishu channel starts under `BullXGateway.AdapterSupervisor`.
3. WebSocket mode receives Feishu events through `FeishuOpenAPI.WS.Client`.
4. Webhook mode verifies and decodes Feishu callbacks through the SDK.
5. Feishu message, edit, recall, reaction, slash command, and card action events normalize to RFC 0002 inputs.
6. Gateway dedupe receives stable IDs for every published Feishu input.
7. Self-sent bot messages are filtered before account gate or publish.
8. `/ping` directly replies `PONG!` through `BullXGateway.deliver/1` without requiring account activation.
9. `/preauth <code>` links a Feishu actor through `BullXAccounts` and maps all RFC 0008 failure atoms to localized replies.
10. `/web_auth` calls `BullXAccounts.issue_user_channel_auth_code/3` and issues a localized linking message only for bound active actors.
11. `/preauth` and `/web_auth` are rejected in group chats without consuming or issuing secrets.
12. Feishu OIDC callback logs in bound users through `BullXAccounts.login_from_provider/1` using `open_id` as `external_id = "feishu:#{open_id}"`.
13. Feishu web login uses Phoenix cookie sessions and does not persist Feishu tokens.
14. Send, edit, and stream delivery work through RFC 0003.
15. Feishu reply fallback for codes `230011` and `231003` degrades to normal chat send when possible.
16. Feishu streaming cards finalize correctly on success, error, and cancellation.
17. Stream DLQ replay with nil content returns `%{"kind" => "payload"}`.
18. Adapter failures return RFC 0003 string-keyed error maps.
19. Failed outbound deliveries enter existing retry/DLQ flow with correct error kind.
20. Feishu adapter emits safe startup, inbound, direct-command, publish-result, and delivery-enqueue logs for manual local runs.
21. All Feishu human-facing text is localized in `en-US` and `zh-Hans-CN` using the application-global locale.
22. No Gateway core behaviour, schema, or public signal contract changes are required.
23. `mix precommit` passes.

## 22. References

- `rfcs/plans/0002_Gateway_Inbound_ControlPlane.md`
- `rfcs/plans/0003_Gateway_Delivery_DLQ.md`
- `rfcs/plans/0007_I18n.md`
- `rfcs/plans/0008_Accounts_AuthN.md`
- `packages/feishu_openapi/README.md`
- `packages/feishu_openapi/README.zh-Hans.md`
- `~/Projects/agentbull-mono/apps/terminal/src/bull-bot/gateway`
- `~/Projects/hermes-agent/gateway/platforms/feishu.py`
- `~/Projects/agentbull-mono/apps/iam/plugins`
- Feishu Open Platform documentation: `https://open.feishu.cn/document/home/index`
- Feishu API generic error codes: `https://open.feishu.cn/document/server-docs/api-call-guide/generic-error-code`
- Feishu API rate limits: `https://open.feishu.cn/document/server-docs/api-call-guide/rate-limit`
