use jsonwebtoken::{Algorithm, EncodingKey};
use rustler::types::binary::Binary;
use rustler::{NifResult, Term};
use serde_json::Value as JsonValue;

use crate::crypto::jwt::claims::{Claims, decode_claims};
use crate::crypto::jwt::header::JwtHeader;
use crate::encoding::error;

/// Sign a JWT.
///
/// `claims` is a map; `key` is the raw secret (HS*) or a PEM-encoded private
/// key (RS/PS/ES/EdDSA); `header` is an optional map. If `iat` is missing,
/// the current Unix timestamp is inserted automatically — matching the JS
/// port's behavior so signed tokens don't accidentally drop a creation time.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_sign(claims: Term<'_>, key: Term<'_>, header: Term<'_>) -> NifResult<String> {
  let mut claims = decode_claims(claims)?;
  let key_bytes = decode_key_bytes(key)?;
  let header = JwtHeader::decode_optional(header)?.into_jwt();

  if !claims.contains_key("iat") {
    claims.insert(
      "iat".to_owned(),
      JsonValue::Number(jsonwebtoken::get_current_timestamp().into()),
    );
  }

  encode(&claims, &header, key_bytes.as_slice())
}

fn encode(claims: &Claims, header: &jsonwebtoken::Header, key: &[u8]) -> NifResult<String> {
  let encoding_key = into_encoding_key(key, header.alg)?;

  jsonwebtoken::encode(header, claims, &encoding_key)
    .map_err(|e| error(format!("jwt sign failed: {e}")))
}

fn into_encoding_key(value: &[u8], alg: Algorithm) -> NifResult<EncodingKey> {
  let key = match alg {
    Algorithm::HS256 | Algorithm::HS384 | Algorithm::HS512 => Ok(EncodingKey::from_secret(value)),
    Algorithm::RS256
    | Algorithm::RS384
    | Algorithm::RS512
    | Algorithm::PS256
    | Algorithm::PS384
    | Algorithm::PS512 => EncodingKey::from_rsa_pem(value),
    Algorithm::ES256 | Algorithm::ES384 => EncodingKey::from_ec_pem(value),
    Algorithm::EdDSA => EncodingKey::from_ed_pem(value),
  };

  key.map_err(|e| error(format!("invalid signing key: {e}")))
}

fn decode_key_bytes<'a>(term: Term<'a>) -> NifResult<Binary<'a>> {
  if !term.is_binary() {
    return Err(error("key must be a binary"));
  }
  Binary::from_term(term).map_err(|_| error("key must be a binary"))
}
