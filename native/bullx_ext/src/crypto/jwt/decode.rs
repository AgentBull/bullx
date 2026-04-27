use rustler::{Env, NifResult, Term};

use crate::crypto::jwt::header::encode_header;
use crate::encoding::error;

/// Decode a JWT's header without verifying its signature.
///
/// Useful for routing decisions (e.g. picking the right key by `kid` or
/// `alg`) before paying the cost of full verification.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_decode_header<'a>(env: Env<'a>, token: Term<'a>) -> NifResult<Term<'a>> {
  let token: String = token
    .decode()
    .map_err(|_| error("token must be a string"))?;

  let header = jsonwebtoken::decode_header(&token)
    .map_err(|e| error(format!("jwt header decode failed: {e}")))?;

  encode_header(env, &header)
}
