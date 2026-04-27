use jsonwebtoken::{Algorithm, Header};
use rustler::types::list::ListIterator;
use rustler::types::map::MapIterator;
use rustler::{Encoder, Env, NifResult, Term, TermType};

use crate::crypto::jwt::algorithm::{algorithm_atom, decode_algorithm};
use crate::encoding::error;

mod atoms {
  rustler::atoms! {
    algorithm,
    content_type,
    json_key_url,
    key_id,
    x5_url,
    x5_cert_chain,
    x5_cert_thumbprint,
    x5t_s256_cert_thumbprint,
    typ = "type",
  }
}

#[derive(Default)]
pub struct JwtHeader {
  pub algorithm: Option<Algorithm>,
  pub content_type: Option<String>,
  pub json_key_url: Option<String>,
  pub key_id: Option<String>,
  pub x5_url: Option<String>,
  pub x5_cert_chain: Option<Vec<String>>,
  pub x5_cert_thumbprint: Option<String>,
  pub x5t_s256_cert_thumbprint: Option<String>,
}

impl JwtHeader {
  /// Convert to a real [`jsonwebtoken::Header`], applying `HS256` as the
  /// default algorithm to match the JWT spec and the reference NodeJS port.
  pub fn into_jwt(self) -> Header {
    let algorithm = self.algorithm.unwrap_or(Algorithm::HS256);
    let mut header = Header::new(algorithm);
    header.typ = Some("JWT".to_owned());
    header.cty = self.content_type;
    header.jku = self.json_key_url;
    header.kid = self.key_id;
    header.x5u = self.x5_url;
    header.x5c = self.x5_cert_chain;
    header.x5t = self.x5_cert_thumbprint;
    header.x5t_s256 = self.x5t_s256_cert_thumbprint;
    header
  }

  /// Decode an optional Elixir map term — `nil`/missing yields the default.
  pub fn decode_optional(term: Term<'_>) -> NifResult<Self> {
    match term.get_type() {
      TermType::Atom => {
        let name: String = term
          .atom_to_string()
          .map_err(|_| error("header must be a map or nil"))?;
        if name == "nil" {
          Ok(Self::default())
        } else {
          Err(error("header must be a map or nil"))
        }
      }
      TermType::Map => Self::decode(term),
      _ => Err(error("header must be a map or nil")),
    }
  }

  fn decode(term: Term<'_>) -> NifResult<Self> {
    let mut header = Self::default();

    let iter = MapIterator::new(term).ok_or_else(|| error("header must be a map"))?;

    for (key, value) in iter {
      let key: String = decode_key(key, "header")?;

      match key.as_str() {
        "algorithm" => header.algorithm = Some(decode_algorithm(value, "header.algorithm")?),
        "content_type" => header.content_type = Some(decode_string(value, "header.content_type")?),
        "json_key_url" => header.json_key_url = Some(decode_string(value, "header.json_key_url")?),
        "key_id" => header.key_id = Some(decode_string(value, "header.key_id")?),
        "x5_url" => header.x5_url = Some(decode_string(value, "header.x5_url")?),
        "x5_cert_chain" => {
          header.x5_cert_chain = Some(decode_string_list(value, "header.x5_cert_chain")?)
        }
        "x5_cert_thumbprint" => {
          header.x5_cert_thumbprint = Some(decode_string(value, "header.x5_cert_thumbprint")?)
        }
        "x5t_s256_cert_thumbprint" => {
          header.x5t_s256_cert_thumbprint =
            Some(decode_string(value, "header.x5t_s256_cert_thumbprint")?)
        }
        other => return Err(error(format!("header: unknown field {other:?}"))),
      }
    }

    Ok(header)
  }
}

/// Encode a [`jsonwebtoken::Header`] into an Elixir map. Missing fields are
/// omitted rather than emitted as `nil`, matching the way Joken returns
/// header decoders. Keys are atoms because the field set is closed and
/// spec-defined.
pub fn encode_header<'a>(env: Env<'a>, header: &Header) -> NifResult<Term<'a>> {
  let mut map = Term::map_new(env);

  map = put(
    map,
    env,
    atoms::algorithm(),
    algorithm_atom(header.alg).encode(env),
  )?;

  if let Some(cty) = &header.cty {
    map = put(map, env, atoms::content_type(), cty.encode(env))?;
  }
  if let Some(jku) = &header.jku {
    map = put(map, env, atoms::json_key_url(), jku.encode(env))?;
  }
  if let Some(kid) = &header.kid {
    map = put(map, env, atoms::key_id(), kid.encode(env))?;
  }
  if let Some(x5u) = &header.x5u {
    map = put(map, env, atoms::x5_url(), x5u.encode(env))?;
  }
  if let Some(x5c) = &header.x5c {
    map = put(map, env, atoms::x5_cert_chain(), x5c.encode(env))?;
  }
  if let Some(x5t) = &header.x5t {
    map = put(map, env, atoms::x5_cert_thumbprint(), x5t.encode(env))?;
  }
  if let Some(x5t_s256) = &header.x5t_s256 {
    map = put(
      map,
      env,
      atoms::x5t_s256_cert_thumbprint(),
      x5t_s256.encode(env),
    )?;
  }
  if let Some(typ) = &header.typ {
    map = put(map, env, atoms::typ(), typ.encode(env))?;
  }

  Ok(map)
}

fn put<'a>(
  map: Term<'a>,
  env: Env<'a>,
  key: rustler::types::atom::Atom,
  value: Term<'a>,
) -> NifResult<Term<'a>> {
  map
    .map_put(key.encode(env), value)
    .map_err(|_| error("failed to build header map"))
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

fn decode_string(term: Term<'_>, field: &str) -> NifResult<String> {
  term
    .decode()
    .map_err(|_| error(format!("{field} must be a string")))
}

fn decode_string_list(term: Term<'_>, field: &str) -> NifResult<Vec<String>> {
  let iter: ListIterator = term
    .decode()
    .map_err(|_| error(format!("{field} must be a list of strings")))?;

  iter
    .map(|item| {
      item
        .decode::<String>()
        .map_err(|_| error(format!("{field} must be a list of strings")))
    })
    .collect()
}
