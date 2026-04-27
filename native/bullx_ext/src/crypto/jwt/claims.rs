use indexmap::IndexMap;
use rustler::types::list::ListIterator;
use rustler::types::map::MapIterator;
use rustler::{Encoder, Env, NifResult, Term, TermType};
use serde_json::{Map as JsonMap, Number as JsonNumber, Value as JsonValue};

use crate::encoding::error;

/// JWT claim set — preserves insertion order so signed payloads are stable
/// across calls and round-trip cleanly through `verify`.
pub type Claims = IndexMap<String, JsonValue>;

/// Convert an Elixir map term into a [`Claims`] payload.
///
/// Atoms become strings (`true`/`false`/`nil` are special-cased to JSON
/// primitives), keys must be strings or atoms, and lists/maps recurse.
pub fn decode_claims(term: Term<'_>) -> NifResult<Claims> {
  if term.get_type() != TermType::Map {
    return Err(error("claims must be a map"));
  }

  let mut claims = Claims::new();
  let iter = MapIterator::new(term).ok_or_else(|| error("claims must be a map"))?;

  for (key_term, value_term) in iter {
    let key = decode_key(key_term, "claims")?;
    claims.insert(key, term_to_json(value_term)?);
  }

  Ok(claims)
}

/// Encode [`Claims`] back to an Elixir term — used by `jwt_verify`.
pub fn encode_claims<'a>(env: Env<'a>, claims: &Claims) -> NifResult<Term<'a>> {
  let mut map = Term::map_new(env);

  for (key, value) in claims {
    let value_term = encode_json(env, value)?;
    map = map
      .map_put(key.encode(env), value_term)
      .map_err(|_| error("failed to build claims map"))?;
  }

  Ok(map)
}

pub(super) fn term_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  match term.get_type() {
    TermType::Atom => atom_to_json(term),
    TermType::Binary => term
      .decode::<String>()
      .map(JsonValue::String)
      .map_err(|_| error("binary value must be valid utf-8")),
    TermType::Integer => term
      .decode::<i64>()
      .map(|n| JsonValue::Number(JsonNumber::from(n)))
      .map_err(|_| error("integer out of range")),
    TermType::Float => term
      .decode::<f64>()
      .ok()
      .and_then(JsonNumber::from_f64)
      .map(JsonValue::Number)
      .ok_or_else(|| error("float not representable in json")),
    TermType::List => list_to_json(term),
    TermType::Map => map_to_json(term),
    other => Err(error(format!("unsupported term type: {other:?}"))),
  }
}

fn encode_json<'a>(env: Env<'a>, value: &JsonValue) -> NifResult<Term<'a>> {
  match value {
    JsonValue::Null => Ok(rustler::types::atom::nil().encode(env)),
    JsonValue::Bool(b) => Ok(b.encode(env)),
    JsonValue::Number(n) => {
      if let Some(i) = n.as_i64() {
        Ok(i.encode(env))
      } else if let Some(u) = n.as_u64() {
        Ok(u.encode(env))
      } else if let Some(f) = n.as_f64() {
        Ok(f.encode(env))
      } else {
        Err(error("number not representable"))
      }
    }
    JsonValue::String(s) => Ok(s.encode(env)),
    JsonValue::Array(items) => {
      let encoded = items
        .iter()
        .map(|item| encode_json(env, item))
        .collect::<NifResult<Vec<_>>>()?;
      Ok(encoded.encode(env))
    }
    JsonValue::Object(obj) => {
      let mut map = Term::map_new(env);
      for (k, v) in obj {
        let value_term = encode_json(env, v)?;
        map = map
          .map_put(k.encode(env), value_term)
          .map_err(|_| error("failed to build map"))?;
      }
      Ok(map)
    }
  }
}

fn atom_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let atom_name: String = term
    .atom_to_string()
    .map_err(|_| error("atom decode failed"))?;

  match atom_name.as_str() {
    "true" => Ok(JsonValue::Bool(true)),
    "false" => Ok(JsonValue::Bool(false)),
    "nil" => Ok(JsonValue::Null),
    other => Ok(JsonValue::String(other.to_string())),
  }
}

fn list_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let iter: ListIterator = term.decode().map_err(|_| error("invalid list value"))?;

  let mut values = Vec::new();
  for element in iter {
    values.push(term_to_json(element)?);
  }

  Ok(JsonValue::Array(values))
}

fn map_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let mut object = JsonMap::new();

  for (k, v) in MapIterator::new(term).ok_or_else(|| error("invalid map value"))? {
    let key = decode_key(k, "map")?;
    object.insert(key, term_to_json(v)?);
  }

  Ok(JsonValue::Object(object))
}

fn decode_key(term: Term<'_>, field: &str) -> NifResult<String> {
  match term.get_type() {
    TermType::Atom => term
      .atom_to_string()
      .map_err(|_| error(format!("{field}: atom keys must be valid utf-8"))),
    TermType::Binary => term
      .decode::<String>()
      .map_err(|_| error(format!("{field}: binary keys must be valid utf-8"))),
    _ => Err(error(format!("{field}: keys must be atoms or binaries"))),
  }
}
