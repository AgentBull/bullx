use jsonwebtoken::{Algorithm, DecodingKey};
use rustler::types::binary::Binary;
use rustler::{Env, NifResult, Term};

use crate::crypto::jwt::claims::{Claims, encode_claims};
use crate::crypto::jwt::validation::JwtValidation;
use crate::encoding::error;

/// Verify a JWT and return its claims as an Elixir map.
///
/// `validation.validate_signature == false` is the only path that calls
/// `jsonwebtoken::dangerous::insecure_decode` — keep the flag separate from
/// the upstream `Validation` so the dangerous path stays explicit.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_verify<'a>(
  env: Env<'a>,
  token: Term<'a>,
  key: Term<'a>,
  validation: Term<'a>,
) -> NifResult<Term<'a>> {
  let token: String = token
    .decode()
    .map_err(|_| error("token must be a string"))?;
  let key_bytes = decode_key_bytes(key)?;
  let validation = JwtValidation::decode_optional(validation)?;

  let claims = decode_token(&token, key_bytes.as_slice(), &validation)?;
  encode_claims(env, &claims)
}

fn decode_token(token: &str, key: &[u8], validation: &JwtValidation) -> NifResult<Claims> {
  let jwt_validation = validation.build();

  let result = if validation.validate_signature == Some(false) {
    jsonwebtoken::dangerous::insecure_decode::<Claims>(token)
  } else {
    let decoding_key = into_decoding_key(key, validation.primary_algorithm())?;
    jsonwebtoken::decode::<Claims>(token, &decoding_key, &jwt_validation)
  };

  result
    .map(|data| data.claims)
    .map_err(|e| error(format!("jwt verify failed: {e}")))
}

fn into_decoding_key(value: &[u8], alg: Algorithm) -> NifResult<DecodingKey> {
  let key = match alg {
    Algorithm::HS256 | Algorithm::HS384 | Algorithm::HS512 => Ok(DecodingKey::from_secret(value)),
    Algorithm::RS256
    | Algorithm::RS384
    | Algorithm::RS512
    | Algorithm::PS256
    | Algorithm::PS384
    | Algorithm::PS512 => DecodingKey::from_rsa_pem(value),
    Algorithm::ES256 | Algorithm::ES384 => DecodingKey::from_ec_pem(value),
    Algorithm::EdDSA => DecodingKey::from_ed_pem(value),
  };

  key.map_err(|e| error(format!("invalid verification key: {e}")))
}

fn decode_key_bytes<'a>(term: Term<'a>) -> NifResult<Binary<'a>> {
  if !term.is_binary() {
    return Err(error("key must be a binary"));
  }
  Binary::from_term(term).map_err(|_| error("key must be a binary"))
}
