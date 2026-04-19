# BullX — Next Generation AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.20-48205D?logo=elixir)](https://elixir-lang.org)

[English](./README.md) | [简体中文](./README.zh-Hans.md) | [日本語](./README.ja.md)

> :warning: **BullX is currently in early development. Expect significant changes and updates.**

**A general-purpose AgentOS — with unique advantages in high-stakes domains like finance.**

BullX is a highly available, self-evolving, and self-healing AI Agent Operating System built on Elixir/OTP and PostgreSQL for long-running, production-grade agent workloads. Its reliability guarantees, durable state, auditable memory, and human-in-the-loop controls matter most in environments where downtime, cost overruns, lost context, or silent failures carry real consequences.

## Highlights

### Production-Grade Runtime

- **Highly Available** — Built on Elixir and Erlang/OTP, a carrier-grade, fault-tolerant language and runtime. Supervision trees handle process scheduling, state ownership, failure isolation, and restart recovery as first-class primitives, so BullX recovers from failures automatically and keeps running through partial outages.
- **Durable State on PostgreSQL** — PostgreSQL is the system of record for sessions, memory, and knowledge, giving BullX transactional writes, replication, and point-in-time recovery out of the box — no bespoke on-disk formats to evolve or migrate.
- **Self-Healing** — Individual agent processes can crash without affecting the rest of the system; supervisors restart them in a known-good state, isolating faults at the process boundary.
- **Built for Long-Running Workflows** — BullX is engineered for agent tasks that run for days or weeks, not seconds — deep research, overnight backtests, continuous monitoring. Scheduled and cron-style jobs execute with **exactly-once semantics** across restarts, failovers, and crashes, so nothing silently drops and nothing silently duplicates.

### Evolving Memory & World Model

- **Self-Evolving Memory** — Memory is a reasoning loop, not a log. BullX extracts structured traces from every interaction at distinct inference levels — direct observations, deductions, inductions, contradictions — while a background consolidation process merges redundancy, detects conflicts between old and new beliefs, and promotes low-level observations into higher-level patterns. Superseded memories are soft-deleted rather than erased, so every conclusion keeps its provenance chain and the system's evolving understanding is reconstructible over time.
- **Ontology-Driven Knowledge Graph** — A typed ontology of entities, relations, and properties forms BullX's world model. Every entity is both a graph node traversable by relation AND a container for its own accumulated reasoning, so planning and recall operate on a shared domain schema rather than loose text snippets. Typed links act as a guardrail against hallucinated relationships at extraction time.
- **Multi-Perspective Memory** — A brain-like memory system has to mirror how minds actually work: the same entity doesn't exist as one shared "objective" record — it lives as a different internal representation in each observer's mind, shaped by that observer's own interaction history. BullX mirrors this at the data layer. Memory is organized by (observer, observed) pairs — each with its own independently-evolving reasoning chain — so distinct and potentially contradictory views of the same entity can coexist, stay self-consistent, and be queried by viewpoint rather than collapsed into a single fused record.

### Perception & Intent

- **Dual-Channel Perception** — Two input channels feed the same reasoning layer: conversations with users or other agents, and external events delivered as **CloudEvents-compliant** triggers (policy changes, market moves, supply-chain disruptions, earnings releases, webhook callbacks). BullX reacts to the world whether or not someone brings it up — essential for domains where signals don't wait for a prompt.
- **Business-Intent Understanding** — A dedicated layer maps incoming requests onto concepts and goals in the business ontology, so the agent plans against what the user is trying to achieve, not the literal words it was given.

### Orchestration & Controls

- **Hybrid Workflow Orchestration** — Compose workflows as finite-state machines, DAGs, or behavior trees whose nodes can be LLM agents, deterministic code, or external services. An LLM can author the topology itself from a high-level goal; once authored, the workflow runs as a structured graph rather than an open-ended agentic loop — dramatically fewer tokens per run, far more predictable and reproducible behavior, and OTP-supervised execution for every node. Use the LLM where thinking is needed, and a compiled graph everywhere else.
- **Budget-Aware with Human-in-the-Loop** — Every workflow tracks cost against configured budgets. Spending caps, permission gates, and approval steps can pause execution and hand decisions to a human reviewer before an agent commits to expensive or irreversible actions — making BullX safe to deploy for workflows that spend real money or touch regulated systems.

## Getting Started

**Prerequisites:** Elixir 1.20+, PostgreSQL

```sh
# Install dependencies, set up the database, and build assets
mix setup

# Start the application (opens an IEx shell + HTTP server)
iex -S mix phx.server
```

Visit `http://localhost:4000`.

**Production:**

```sh
MIX_ENV=prod mix release
_build/prod/rel/bullx/bin/bullx start
```

## Configuration

BullX has two configuration phases:

**Bootstrap configuration** — values required before the application starts (database URL, port, secret key). These remain in the standard `config/*.exs` files and are read at startup through shared helpers in `config/support/bootstrap.exs`. They support `.env` file loading but do not read from PostgreSQL.

**Runtime dynamic configuration** — values that can be changed without restarting. Declared with `BullX.Config` and resolved in this order: PostgreSQL override → OS environment → code default. Reads are served from an ETS cache; writes refresh the cache explicitly.

**`.env` file support** — place a `.env.example`-style file at the repo root to provide local overrides. Files are merged in this order (later wins, existing OS env always wins):

| Environment | Load order |
|---|---|
| Development | `.env` → `.env.development` → `.env.local` |
| Test | `.env` → `.env.test` |
| Production | `.env` → `.env.production` |

> `.env.local` is gitignored and intended for machine-specific secrets. `.env`, `.env.development`, and `.env.test` may be committed as shared non-secret team defaults.

**Runtime value constraints** — runtime settings may declare a [Zoi](https://hex.pm/packages/zoi) schema alongside their type. A value that fails the Zoi constraint is silently skipped and the next source in the fallback chain is tried.

**Changing a runtime setting at runtime:**

```elixir
# Store a new value in PostgreSQL and refresh the local ETS cache
BullX.Config.put("bullx.gateway_webhook_timeout_ms", "5000")

# Remove an override; the setting falls back to OS env or default
BullX.Config.delete("bullx.gateway_webhook_timeout_ms")
```
