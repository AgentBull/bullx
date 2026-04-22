# RFC 0004: BullX Ext Encoding NIFs

- **Status**: Draft
- **Author**: Codex
- **Created**: 2026-04-22

## 1. Purpose

Extend `native/bullx_ext` with a small encoding surface that is callable through
`BullX.Ext`:

- UUID generation and short UUID helpers
- Base58 encode/decode
- URL-safe Base64 encode/decode without padding
- AnyAscii transliteration
- Z85 encode/decode

The goal is to add these capabilities without changing BullX's Elixir-side
architecture or introducing a new public wrapper module.

## 2. Scope

### In scope

- Add Rust modules under `native/bullx_ext/src/encoding/`
- Wire those modules into `native/bullx_ext/src/lib.rs`
- Add the minimal crate dependencies required for the new encoders
- Expose matching stubs in `lib/bullx/ext.ex`
- Add tests that prove the new NIF API works from Elixir

### Out of scope

- New OTP processes, supervisors, or runtime state
- New Elixir wrapper modules beyond `BullX.Ext`
- Reworking existing Blake3 NIF APIs

## 3. Cleanup Plan

- **Dead code to delete**: none expected; this change is additive.
- **Duplicate logic to merge**: shared Rustler binary/string decoding and binary
  return helpers should live in the encoding area instead of being reimplemented
  in every new module.
- **Existing utilities or patterns to reuse**:
  - keep using `rustler::init!("Elixir.BullX.Ext")`
  - keep using `NifResult<T>` and `Error::Term(...)` for tagged Elixir errors
  - keep exposing public functions directly on `BullX.Ext`
- **Actual code path changing**:
  - Rust NIF export surface in `native/bullx_ext`
  - Elixir stub surface in `BullX.Ext`
  - test coverage for the NIF contract
- **Invariant that must remain true**:
  - `BullX.Ext` remains the single public entry point for the crate
  - invalid arguments and decode failures still return tagged error tuples
  - no supervision or persistence boundary changes
- **Verification commands**:
  - `cargo test -p bullx_ext`
  - `mix test test/bullx/ext_test.exs`
  - `mix precommit`

## 4. Implementation Notes

- Encoding functions that operate on caller-provided binaries should accept
  Elixir binaries directly.
- Decode functions should return Elixir binaries, not lists of integers.
- UUID helpers should provide:
  - v4 generation
  - v7 generation
  - base36 generation
  - Base58 shortening / expansion for canonical UUID strings

## 5. Acceptance Criteria

- `BullX.Ext` exposes working functions for UUID, Base58, Base64, AnyAscii, and
  Z85 helpers.
- New Rust unit tests cover the pure helper logic.
- Elixir tests cover the user-facing NIF contract, including error cases.
