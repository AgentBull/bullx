use jsonwebtoken::{Algorithm, Validation};
use rustler::types::list::ListIterator;
use rustler::types::map::MapIterator;
use rustler::{NifResult, Term, TermType};

use crate::crypto::jwt::algorithm::decode_algorithm;
use crate::encoding::error;

#[derive(Default)]
pub struct JwtValidation {
  pub aud: Option<Vec<String>>,
  pub required_spec_claims: Option<Vec<String>>,
  pub leeway: Option<u64>,
  pub validate_exp: Option<bool>,
  pub validate_nbf: Option<bool>,
  pub sub: Option<String>,
  pub algorithms: Option<Vec<Algorithm>>,
  pub iss: Option<Vec<String>>,
  /// `Some(false)` triggers `jsonwebtoken::dangerous::insecure_decode` at the
  /// call site — kept separate from the upstream `Validation` because that
  /// type doesn't expose the flag.
  pub validate_signature: Option<bool>,
}

impl JwtValidation {
  /// Decode an optional Elixir map term. `nil` / missing yields the default
  /// validation (HS256, validate `exp` only, 60-second leeway).
  pub fn decode_optional(term: Term<'_>) -> NifResult<Self> {
    match term.get_type() {
      TermType::Atom => {
        let name: String = term
          .atom_to_string()
          .map_err(|_| error("validation must be a map or nil"))?;
        if name == "nil" {
          Ok(Self::default())
        } else {
          Err(error("validation must be a map or nil"))
        }
      }
      TermType::Map => Self::decode(term),
      _ => Err(error("validation must be a map or nil")),
    }
  }

  fn decode(term: Term<'_>) -> NifResult<Self> {
    let mut validation = Self::default();
    let iter = MapIterator::new(term).ok_or_else(|| error("validation must be a map"))?;

    for (key, value) in iter {
      let key = decode_key(key, "validation")?;

      match key.as_str() {
        "aud" => validation.aud = Some(decode_string_list(value, "validation.aud")?),
        "required_spec_claims" => {
          validation.required_spec_claims = Some(decode_string_list(
            value,
            "validation.required_spec_claims",
          )?)
        }
        "leeway" => {
          validation.leeway = Some(
            value
              .decode::<u64>()
              .map_err(|_| error("validation.leeway must be a non-negative integer"))?,
          )
        }
        "validate_exp" => {
          validation.validate_exp = Some(
            value
              .decode::<bool>()
              .map_err(|_| error("validation.validate_exp must be a boolean"))?,
          )
        }
        "validate_nbf" => {
          validation.validate_nbf = Some(
            value
              .decode::<bool>()
              .map_err(|_| error("validation.validate_nbf must be a boolean"))?,
          )
        }
        "sub" => {
          validation.sub = Some(
            value
              .decode::<String>()
              .map_err(|_| error("validation.sub must be a string"))?,
          )
        }
        "algorithms" => {
          let iter: ListIterator = value
            .decode()
            .map_err(|_| error("validation.algorithms must be a list of atoms"))?;
          validation.algorithms = Some(
            iter
              .map(|item| decode_algorithm(item, "validation.algorithms"))
              .collect::<NifResult<Vec<_>>>()?,
          );
        }
        "iss" => validation.iss = Some(decode_string_list(value, "validation.iss")?),
        "validate_signature" => {
          validation.validate_signature = Some(
            value
              .decode::<bool>()
              .map_err(|_| error("validation.validate_signature must be a boolean"))?,
          )
        }
        other => return Err(error(format!("validation: unknown field {other:?}"))),
      }
    }

    Ok(validation)
  }

  /// Build the upstream [`Validation`] struct.
  ///
  /// The default algorithm is HS256, matching the JWT spec and the JS port.
  /// The `validate_signature` flag is intentionally not represented here —
  /// callers consult [`Self::validate_signature`] directly to decide between
  /// `jsonwebtoken::decode` and `jsonwebtoken::dangerous::insecure_decode`.
  pub fn build(&self) -> Validation {
    let mut validation = Validation::new(Algorithm::HS256);

    if let Some(aud) = &self.aud {
      validation.set_audience(aud);
    } else {
      validation.validate_aud = false;
    }
    if let Some(required) = &self.required_spec_claims {
      validation.set_required_spec_claims(required);
    }
    if let Some(leeway) = self.leeway {
      validation.leeway = leeway;
    }
    if let Some(validate_exp) = self.validate_exp {
      validation.validate_exp = validate_exp;
    }
    if let Some(validate_nbf) = self.validate_nbf {
      validation.validate_nbf = validate_nbf;
    }
    if let Some(sub) = &self.sub {
      validation.sub = Some(sub.clone());
    }
    if let Some(algorithms) = &self.algorithms {
      validation.algorithms = algorithms.clone();
    }
    if let Some(iss) = &self.iss {
      validation.set_issuer(iss);
    }

    validation
  }

  /// Algorithm to use for building the decoding key. Defaults to HS256 to
  /// match `Validation::new(HS256)` so callers don't have to special-case the
  /// missing-algorithms-list path.
  pub fn primary_algorithm(&self) -> Algorithm {
    self
      .algorithms
      .as_ref()
      .and_then(|algs| algs.first().copied())
      .unwrap_or(Algorithm::HS256)
  }
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
