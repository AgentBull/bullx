//! JWT NIFs (RFC 7519).
//!
//! Mirrors the [`jsonwebtoken`](https://docs.rs/jsonwebtoken/) feature set —
//! HS/RS/PS/ES/EdDSA signing, validation with leeway, audience/issuer/subject
//! checks, and unauthenticated header decoding.
//!
//! Claims are represented as an [`indexmap::IndexMap`] so the order of keys is
//! preserved between Elixir and the encoded JWT, matching the Joken-style
//! default of `iat` being prepended automatically when missing.

pub mod algorithm;
pub mod claims;
pub mod decode;
pub mod header;
pub mod sign;
pub mod validation;
pub mod verify;
