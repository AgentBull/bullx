use jsonwebtoken::Algorithm;
use rustler::{NifResult, Term};

use crate::encoding::error;

mod atoms {
  rustler::atoms! {
    hs256,
    hs384,
    hs512,
    rs256,
    rs384,
    rs512,
    ps256,
    ps384,
    ps512,
    es256,
    es384,
    ed_dsa,
  }
}

/// Decode an Elixir atom such as `:hs256` or `:ed_dsa` into a
/// [`jsonwebtoken::Algorithm`]. The naming mirrors `Joken.Signer` aliases so
/// callers don't need to learn a NIF-specific dialect.
pub fn decode_algorithm(term: Term<'_>, field: &str) -> NifResult<Algorithm> {
  let atom: rustler::types::atom::Atom = term
    .decode()
    .map_err(|_| error(format!("{field} must be an atom")))?;

  match atom {
    a if a == atoms::hs256() => Ok(Algorithm::HS256),
    a if a == atoms::hs384() => Ok(Algorithm::HS384),
    a if a == atoms::hs512() => Ok(Algorithm::HS512),
    a if a == atoms::rs256() => Ok(Algorithm::RS256),
    a if a == atoms::rs384() => Ok(Algorithm::RS384),
    a if a == atoms::rs512() => Ok(Algorithm::RS512),
    a if a == atoms::ps256() => Ok(Algorithm::PS256),
    a if a == atoms::ps384() => Ok(Algorithm::PS384),
    a if a == atoms::ps512() => Ok(Algorithm::PS512),
    a if a == atoms::es256() => Ok(Algorithm::ES256),
    a if a == atoms::es384() => Ok(Algorithm::ES384),
    a if a == atoms::ed_dsa() => Ok(Algorithm::EdDSA),
    _ => Err(error(format!("{field}: unsupported algorithm"))),
  }
}

/// Render a [`jsonwebtoken::Algorithm`] back into the matching atom for
/// returning through the NIF boundary.
pub fn algorithm_atom(alg: Algorithm) -> rustler::types::atom::Atom {
  match alg {
    Algorithm::HS256 => atoms::hs256(),
    Algorithm::HS384 => atoms::hs384(),
    Algorithm::HS512 => atoms::hs512(),
    Algorithm::RS256 => atoms::rs256(),
    Algorithm::RS384 => atoms::rs384(),
    Algorithm::RS512 => atoms::rs512(),
    Algorithm::PS256 => atoms::ps256(),
    Algorithm::PS384 => atoms::ps384(),
    Algorithm::PS512 => atoms::ps512(),
    Algorithm::ES256 => atoms::es256(),
    Algorithm::ES384 => atoms::es384(),
    Algorithm::EdDSA => atoms::ed_dsa(),
  }
}
