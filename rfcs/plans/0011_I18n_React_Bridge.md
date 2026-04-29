# RFC 0011: I18n React Bridge

**Status**: Implementation plan  
**Author**: OpenAI CodeX
**Created**: 2026-04-27  
**Depends on**: RFC 0007

## 1. TL;DR

RFC 0007 made `priv/locales/*.toml` plus MessageFormat 2 the source of truth for **server-side** BullX translations. This RFC adds **front-end** translations under `priv/locales/client/*.toml`, bundled by Rsbuild into the React app and consumed through an in-browser i18next runtime.

Front-end and back-end share the TOML format and the BCP 47 locale-tag convention. They share nothing else:

- `priv/locales/<bcp47>.toml` — server-only translations. Loaded by `BullX.I18n.Catalog`. Unchanged by this RFC.
- `priv/locales/client/<bcp47>.toml` — client-only translations. Loaded at Rsbuild build time as static modules, registered as i18next resources.

The only coupling between the two sides is the active locale, propagated via `<html lang>` (server-set, client-read at boot). There is no Inertia bridge for translations, no catalog export endpoint, no allowlist, no payload revision, no fallback-chain mirroring. Each side reads its own files and runs its own engine.

```tsx
const { t } = useTranslation()

t("web.sessions.new.title")
t("web.sessions.new.placeholder", { values: { form_action: formAction } })

<Trans i18nKey="web.cart.summary" values={{ count }} />
```

### 1.1 Cleanup Plan

- **Dead code to delete**
  - None. Current React pages use hard-coded English strings that are active placeholders. Implementation replaces them with i18next calls page by page.
- **Patterns NOT to introduce**
  - A separate BullX React translation API that competes with `react-i18next`.
  - Cross-runtime alignment between Elixir Localize and JS messageformat.
  - The `mf2react` npm dependency. We replicate its ~100 lines in-tree.
  - An Inertia prop for translations.
  - A server-side catalog export adapter or plug.
  - A browser-side allowlist or prefix filter.
  - A client-side reconstruction of the server resolver's fallback chain.
- **Existing utilities to reuse**
  - The existing `BullXWeb.I18n.HTML` server helper (extended with `lang/0` and `dir/0` for the `<html>` tag).
  - The existing `priv/locales/*.toml` scanning + MF2 validation pattern from RFC 0007 — extended to a second directory in `mix i18n.check`.
  - `react-i18next` for React context and rendering.
- **Code paths changing**
  - New `priv/locales/client/*.toml` directory with `web.*` keys.
  - New Rsbuild TOML loader plugin so React can `import` the locale files.
  - New `webui/src/i18n/` initializer (mf2 post-processor + i18next init + provider).
  - `root.html.heex` reads `<html lang>` from the active locale.
  - Existing React SPA copy moves from hard-coded strings to `t(...)` / `<Trans>` calls.
  - `mix i18n.check` additionally validates `priv/locales/client/*.toml`.
- **Invariants that must remain true**
  - TOML is the only translation file format. Front-end TOMLs live at `priv/locales/client/`; back-end TOMLs at `priv/locales/`. No JSON catalogs anywhere in the source tree.
  - Loaded locales are always complete BCP 47 tags (RFC 0007 §4.4).
  - `BullX.I18n.Catalog` only reads `priv/locales/*.toml` (top-level). The `client/` subdirectory is invisible to the server runtime.
  - Locale remains application-global; no browser language detector, localStorage locale, URL locale segment, or user locale is introduced here.
  - Missing keys and format errors degrade to visible strings; they do not break page rendering.
- **Verification commands**
  - `mix i18n.check` (validates both directories)
  - `bun run build`
  - `mix precommit`

## 2. Scope

### 2.1 In Scope

- React pages rendered by the existing Rsbuild + Inertia stack.
- Browser-side rendering of MF2 messages from `priv/locales/client/*.toml`.
- `react-i18next` component usage through `useTranslation` and `Trans`.
- Basic safe MF2 markup aliases (`bold` / `b` / `strong`, `i` / `italic` / `em`, `u`, `s`, `code`, `small`, `br`).
- Rsbuild TOML loader so client locale files import as JS objects.
- Active-locale propagation through `<html lang>`.
- `<html dir>` set from the server side.
- `mix i18n.check` extension to validate client TOMLs.
- `web.*` keys for the existing React SPAs:
  - `webui/src/apps/control-panel/App.jsx`
  - `webui/src/apps/setup/App.jsx`
  - `webui/src/apps/sessions/New.jsx`

`app.*` keys (including `app.connectivity.*`, `app.close`, `app.actions`) stay in `priv/locales/*.toml`. They are consumed by server-side HEEx components (`BullXWeb.CoreComponents`, `BullXWeb.Layouts`), not by React. Whichever side renders the markup owns the key; nothing forces the namespace to follow the prefix.

### 2.2 Out of Scope

- Per-user locales.
- `Accept-Language` negotiation.
- A language switcher.
- Client-side persistence of locale.
- Arbitrary React component interpolation in translations.
- Server-side rendering for Inertia.
- Client localization for LiveView. HEEx/LiveView already uses `BullXWeb.I18n.HTML` from RFC 0007.
- Cross-runtime output alignment between Elixir Localize and JS messageformat.
- A runtime catalog export endpoint or Inertia bridge.
- Translating every existing server key into a browser catalog.

## 3. Current State

The server side already has:

- `BullX.I18n.t/3` and `translate/3`.
- A `BullX.I18n.Catalog` GenServer that loads `priv/locales/*.toml`.
- `BullX.I18n.Resolver` fallback-chain lookup over `:persistent_term`.
- `BullXWeb.I18n.HTML` imported into controllers/templates.
- `BullXWeb.I18n.ErrorTranslator` for Ecto errors.
- `mix i18n.check`.

The frontend side currently has:

- Rsbuild config in `rsbuild.config.mjs`.
- A single React/Inertia entrypoint in `webui/src/app.jsx`.
- React pages under `webui/src/apps/**`.
- Hard-coded English UI strings in those React pages.
- No frontend i18n runtime or catalog.

The gap is an Rsbuild-bundled i18next runtime backed by a separate set of TOML files for client copy.

## 4. Design Decisions

### 4.1 File layout

```text
priv/locales/
├── en-US.toml              # server-only (gateway, agent, errors, app.*, …)
├── zh-Hans-CN.toml         # server-only
└── client/
    ├── en-US.toml          # client-only (web.*)
    └── zh-Hans-CN.toml     # client-only
```

The `BullX.I18n.Loader` is non-recursive (`File.ls/1` + `.toml` suffix filter), so the existing Catalog naturally ignores `client/`. The FileSystem watcher in `BullX.I18n.Catalog` may notice `client/` writes and trigger a no-op rescan; that is acceptable.

A given translation key lives in exactly one directory. Keys are not duplicated across server and client. Whichever side renders the UI element owns the key.

### 4.2 React API

React uses i18next APIs directly. BullX does not wrap them in a custom layer.

```tsx
import { useTranslation } from "react-i18next"

export function Header() {
  const { t } = useTranslation()
  return <h1>{t("web.control_panel.heading")}</h1>
}
```

MF2 variables:

```tsx
t("web.sessions.new.placeholder", {
  values: { form_action: formAction },
})
```

Markup-bearing messages:

```tsx
import { Trans } from "react-i18next"

<Trans i18nKey="web.cart.summary" values={{ count }} />
```

BullX frontend convention is to pass MF2 bindings under `values` rather than as top-level i18next options. This avoids collisions with reserved options such as `lng`, `ns`, `keyPrefix`, `defaultValue`, and `postProcess`.

### 4.3 Active locale propagation

Server-side root layout sets `<html lang>` and `<html dir>`:

```heex
<html lang={BullXWeb.I18n.HTML.lang()} dir={BullXWeb.I18n.HTML.dir()}>
```

`BullXWeb.I18n.HTML.lang/0` returns the BCP 47 string of `BullX.I18n.default_locale/0` (e.g. `"zh-Hans-CN"`). `dir/0` returns `"ltr"` until an RTL locale is added.

React reads the active locale from `document.documentElement.lang` at i18next init. No other locale signal is sent or read.

### 4.4 Browser runtime

```ts
// webui/src/i18n/i18n.ts
import i18n from "i18next"
import { initReactI18next } from "react-i18next"
import { Mf2PostProcessor, Mf2ReactPreset } from "./mf2"

import enUS from "@locales/en-US.toml"
import zhHansCN from "@locales/zh-Hans-CN.toml"

const resources = {
  "en-US": { translation: enUS },
  "zh-Hans-CN": { translation: zhHansCN },
}

const lng = document.documentElement.lang || "en-US"

i18n
  .use(Mf2PostProcessor)
  .use(Mf2ReactPreset)
  .use(initReactI18next)
  .init({
    lng,
    fallbackLng: "en-US",
    resources,
    defaultNS: "translation",
    ns: ["translation"],
    postProcess: ["mf2"],
    load: "currentOnly",
    interpolation: { escapeValue: false },
    react: { useSuspense: false },
  })

export default i18n
```

`webui/src/i18n/mf2.ts` (~100 lines, adapted from public `mf2react` source) exports:

- `Mf2PostProcessor` — i18next post-processor (`name: "mf2"`) that compiles each translated string with the `messageformat` package's `MessageFormat`, caches compiled messages by `${lng}__${source}`, calls `formatToParts`, and renders the result to safe HTML markup. On compile or format failure, falls back to a curly-tag-to-angle-bracket conversion of the raw source.
- `Mf2ReactPreset` — 3rd-party plugin that flips `react.transSupportBasicHtmlNodes: true` and adds the safe alias list (`strong`, `em`, `br`, `u`, `s`, `code`, `small`) to `react.transKeepBasicHtmlNodesFor` so `<Trans>` renders those tags as JSX.

Reasons for inlining instead of depending on `mf2react`:

- The total surface is ~100 lines of straightforward code; the dependency footprint is not worth the version pin.
- Local control over the markup alias list, cache key strategy, and error-fallback policy.

### 4.5 Resource shape

`priv/locales/client/<bcp47>.toml` files are normal TOML with nested tables, e.g.:

```toml
[web.sessions.new]
title = "Sign In"
placeholder = "Login screen placeholder. Auth-code submission will post to {$form_action}."
```

The Rsbuild TOML loader (§5) parses this into a nested JS object:

```json
{
  "web": {
    "sessions": {
      "new": {
        "title": "Sign In",
        "placeholder": "Login screen placeholder. Auth-code submission will post to {$form_action}."
      }
    }
  }
}
```

i18next consumes that as the `translation` namespace. React calls `t("web.sessions.new.title")`; i18next's default `keySeparator: "."` resolves the nested resource.

`__meta__` is a reserved top-level table on the server side; it is conventionally omitted from client TOMLs (no fallback declarations in client files; cross-locale fallback is i18next's hardcoded `fallbackLng: "en-US"`).

### 4.6 Text and markup

Plain strings use `t`.

Messages with safe inline emphasis use MF2 curly tags and `<Trans>`:

```toml
[web.cart]
summary = '''
.input {$count :number}
.match $count
  1 {{{#strong}1{/strong} item}}
  * {{{#strong}{$count}{/strong} items}}
'''
```

```tsx
<Trans i18nKey="web.cart.summary" values={{ count }} />
```

Allowed tag list:

```text
bold, b, strong, i, italic, em, br, u, s, code, small
```

No arbitrary HTML, no arbitrary component names, no links / buttons / business actions in translations. Links and interactive components stay in React.

## 5. Rsbuild integration

### 5.1 TOML loader plugin

Add a small Rsbuild plugin to `rsbuild.config.mjs`:

```js
import { parse as parseToml } from "@iarna/toml"

function tomlPlugin() {
  return {
    name: "bullx-toml",
    setup(api) {
      api.transform({ test: /\.toml$/ }, ({ code }) => ({
        code: `export default ${JSON.stringify(parseToml(code))}`,
        map: null,
      }))
    },
  }
}
```

Add the alias:

```js
resolve: {
  alias: {
    "@locales": resolve(appRoot, "priv/locales/client"),
    // ...existing aliases
  },
},
plugins: [
  // ...existing plugins
  tomlPlugin(),
]
```

`@iarna/toml` is the JS TOML parser; install as a dev dependency.

### 5.2 Dev hot reload

Rspack watches imported TOML modules. To make changes under `priv/locales/client/` trigger a page reload consistently, add a dev watcher:

```js
dev: {
  watchFiles: {
    paths: resolve(appRoot, "priv/locales/client/*.toml"),
    type: "reload-page",
  },
}
```

Production catalog changes require a re-build, matching how every other front-end source change works.

## 6. Server-side wiring

### 6.1 `<html lang>` and `<html dir>`

Extend `BullXWeb.I18n.HTML` with:

```elixir
def lang do
  case BullX.I18n.default_locale() do
    %Localize.LanguageTag{requested_locale_id: id} when is_atom(id) ->
      Atom.to_string(id)

    _ ->
      "en-US"
  end
end

def dir, do: "ltr"
```

`dir/0` returns `"ltr"` until an RTL locale is added; the helper is the future hook point.

Update `lib/bullx_web/components/layouts/root.html.heex`:

```heex
<html lang={BullXWeb.I18n.HTML.lang()} dir={BullXWeb.I18n.HTML.dir()}>
```

That is the entire server-side change.

## 7. React Design

### 7.1 Dependencies

```text
i18next
react-i18next
messageformat
@iarna/toml          # devDependency, used by the Rsbuild plugin
```

Do not add `mf2react` (replicated in-tree).
Do not add `i18next-browser-languagedetector` (locale is global, read from `<html lang>`).
Do not add `i18next-http-backend` (resources bundled at build time).

### 7.2 Files

```text
webui/src/i18n/mf2.ts        # post-processor + preset (~100 lines)
webui/src/i18n/i18n.ts       # i18next init, exports the singleton
webui/src/i18n/provider.tsx  # <I18nextProvider> wrapper
```

### 7.3 Provider

```tsx
import { I18nextProvider } from "react-i18next"
import i18n from "./i18n"

export function BullXI18nextProvider({ children }) {
  return <I18nextProvider i18n={i18n}>{children}</I18nextProvider>
}
```

The provider takes no props. Active locale is fixed at module-load time from `<html lang>`.

### 7.4 Inertia wiring

Wrap the rendered page in the provider inside `webui/src/app.jsx`:

```jsx
import { BullXI18nextProvider } from "./i18n/provider"

createInertiaApp({
  // ...existing config
  setup({ App, el, props }) {
    createRoot(el).render(
      <BullXI18nextProvider>
        <App {...props} />
      </BullXI18nextProvider>,
    )
  },
})
```

No Inertia prop is read or written for translations.

### 7.5 Page Usage

Simple text:

```tsx
const { t } = useTranslation()

<Head title={t("web.setup.title")} />
<CardTitle>{t("web.setup.heading")}</CardTitle>
```

MF2 variables:

```tsx
<p>
  {t("web.sessions.new.placeholder", {
    values: { form_action: formAction },
  })}
</p>
```

Translated markup:

```tsx
<Trans i18nKey="web.cart.summary" values={{ count }} />
```

### 7.6 Page Key Layout

Initial keys for `priv/locales/client/en-US.toml`:

```toml
[web.sessions.new]
title = "Sign In"
brand = "BullX"
placeholder = "Login screen placeholder. Auth-code submission will post to {$form_action}."

[web.setup]
title = "Setup"
heading = "Initial setup wizard"
description = "This SPA is available only while the Users table is empty. The first-user setup flow will live here."
placeholder = "Setup form placeholder"

[web.control_panel]
title = "Control Panel"
subtitle = "Control Panel SPA"
status = "Authenticated"
heading = "Operator console"
api_title = "API"
openapi_json = "OpenAPI JSON"
swagger_ui = "Swagger UI"

[web.control_panel.sections.sessions]
title = "Sessions"
description = "Active runtime sessions will be managed here."
```

`priv/locales/client/zh-Hans-CN.toml` mirrors the same key set.

`app.*` keys (including `app.connectivity.*`) stay in `priv/locales/`. They are rendered server-side by HEEx components and never read by React.

## 8. `mix i18n.check`

Extend the existing task to additionally scan `priv/locales/client/*.toml`:

- Parse each file with TomlElixir under spec `:"1.1.0"`.
- Run each leaf through `BullX.I18n.Normalizer.normalize/2` so MF2 syntax errors fail CI.
- Validate that every non-source-language client file's key set is a subset of the `en-US` client file's key set, mirroring the existing rule for server files.

The two scans are independent. A server key missing in the client set is fine. A client key missing in the server set is also fine.

## 9. Implementation Steps

1. Add `BullXWeb.I18n.HTML.lang/0` and `dir/0`.
2. Update `root.html.heex` to use the helpers.
3. Create `priv/locales/client/en-US.toml` and `priv/locales/client/zh-Hans-CN.toml` with the §7.6 key set.
4. Add `i18next`, `react-i18next`, `messageformat`, and `@iarna/toml` to `package.json`.
5. Add the TOML loader plugin and `@locales` alias to `rsbuild.config.mjs`.
6. Add the client-locales reload watcher to `rsbuild.config.mjs`.
7. Add `webui/src/i18n/mf2.ts` (post-processor and preset).
8. Add `webui/src/i18n/i18n.ts` (init) and `provider.tsx` (wrapper).
9. Wrap `createInertiaApp`'s `setup` render in `<BullXI18nextProvider>`.
10. Replace hard-coded React strings with `useTranslation()` and `<Trans>`.
11. Extend `mix i18n.check` to scan `priv/locales/client/*.toml`.

## 10. Tests

### 10.1 Elixir Tests

- `BullXWeb.I18n.HTML.lang/0` returns the configured locale's BCP 47 string.
- `mix i18n.check` flags an MF2 syntax error in a client TOML.
- `mix i18n.check` flags a key missing from a non-source client TOML.
- `BullX.I18n.Catalog` does not load any keys from `priv/locales/client/`.

### 10.2 JavaScript Tests

A unit test for `webui/src/i18n/mf2.ts` covering:

- Compiling and rendering an MF2 string with `.match`.
- Curly-tag-to-HTML conversion for the supported alias list.
- Caching by `${lng}__${source}`.
- Graceful fallback to raw curly-tag-to-angle-bracket conversion on compile failure.

### 10.3 Build Verification

```text
mix test test/bullx/i18n
mix i18n.check
bun run build
mix precommit
```

## 11. Risks

- **`mf2.ts` and `Localize` diverge in formatting output.** Acknowledged tradeoff. They render different UI surfaces; alignment is not required.
- **Client TOML drift between locales.** Mitigated by `mix i18n.check` extension.
- **An operator copies a server-only string into `priv/locales/client/`.** Discipline issue; review catches it. Not architecturally enforced.
- **`@iarna/toml`'s parser disagrees with `toml_elixir` on a corner case.** Both target TOML 1.1; deviations are extremely unlikely for the simple key-value shapes used here. If discovered, swap the JS parser.

## 12. Future Work

- Per-user locale support, if a later RFC changes the global-locale assumption.
- An RTL locale (Arabic / Hebrew); requires `dir/0` to look up direction by locale.
- Optional client-side form validation messages under `web.forms.*`.

## 13. References

- Unicode MessageFormat 2: https://messageformat.unicode.org/
- `messageformat` npm package: https://www.npmjs.com/package/messageformat
- `mf2react` npm package (reference for the in-tree post-processor): https://www.npmjs.com/package/mf2react
- `@iarna/toml` npm package: https://www.npmjs.com/package/@iarna/toml
