# BullX Agent Guidelines

BullX is a highly available, self-evolving AI Agent Operating System built on Elixir/OTP and PostgreSQL. The codebase is organized into six subsystems that boot under a single OTP supervision tree. PostgreSQL is the system of record for sessions, memory, and knowledge; process-local state is ephemeral and reconstructible on restart.

## Subsystems

- **Gateway** (`lib/bullx/gateway/`) — multi-transport ingress and egress. Normalizes inbound events from external sources (HTTP polling, subscribed WebSockets, webhooks, channel adapters like Feishu/Slack/Telegram) into internal signals, and dispatches outbound messages back to those destinations.
- **Runtime** (`lib/bullx/runtime/`) — the long-lived process layer. Owns session processes, LLM/tool task pools, sub-agent supervision, and cron scheduling with exactly-once semantics across restarts.
- **AIAgent** (`lib/bullx/ai_agent/`) — the AI Agent behavior layer. Prompt types, reasoning strategies (FSM / DAG / behavior tree), and decision logic. Forked from jido_ai v2.1.0 and substantially rewritten for BullX's needs, so BullX does not depend on `jido_ai` as a package.
- **Brain** (`lib/bullx/brain/`) — persistent memory and knowledge graph. A typed ontology of objects, links, and properties forms the skeleton; `(observer, observed)`-keyed cortexes hold engrams (LLM-extracted reasoning traces at distinct inference levels). A background Dreamer process consolidates engrams, detects contradictions, and promotes abstraction level.
- **Skills** (`lib/bullx/skills/`) — registry of preset and custom capabilities. Every skill is backed by a validated `Jido.Action`.
- **Control plane** (`lib/bullx_web/`) — Phoenix app. Operator-facing web console (budgets, approvals, HITL queues, audit trails, observability) and the HTTP surface for the system.

Confirm which subsystem you are editing before applying the framework-specific rules below. The Elixir, Mix, Test, and Ecto rules apply everywhere. The Phoenix / LiveView / HEEx / Tailwind rules apply only to code under `lib/bullx_web`.

## Plan-first workflow

BullX implements features and fixes complex bugs through a plan-first process:

1. A human writes a plan in `rfcs/plans/` that specifies the full scope of the work — files to create or modify, expected module shapes, and acceptance criteria.
2. A coding agent executes the plan. The plan is the source of truth; deviations require explicit justification.
3. The plan stays committed in the repo as a record of design intent.


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
- Use the already included `:req` (`Req`) library for HTTP requests — **avoid** `:httpoison`, `:tesla`, and `:httpc`

## Phoenix subsystem (lib/bullx_web only)

> The following three sections — Phoenix v1.8, JS and CSS, UI/UX & design — apply only when editing code under `lib/bullx_web`.

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such an option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->
