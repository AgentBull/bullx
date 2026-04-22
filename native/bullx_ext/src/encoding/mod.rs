use rustler::types::binary::{Binary, OwnedBinary};
use rustler::{Error, NifResult, Term};

pub mod any_ascii;
pub mod base58;
pub mod base64;
pub mod uuid;
pub mod z85;

pub(crate) fn decode_binary<'a>(term: Term<'a>, field: &str) -> NifResult<Binary<'a>> {
  if !term.is_binary() {
    return Err(error(format!("{field} must be a binary")));
  }

  Binary::from_term(term).map_err(|_| error(format!("{field} must be a binary")))
}

pub(crate) fn decode_string(term: Term<'_>, field: &str) -> NifResult<String> {
  term
    .decode()
    .map_err(|_| error(format!("{field} must be a string")))
}

pub(crate) fn binary_from_vec(bytes: Vec<u8>) -> NifResult<OwnedBinary> {
  let mut binary =
    OwnedBinary::new(bytes.len()).ok_or_else(|| error("failed to allocate binary"))?;
  binary.as_mut_slice().copy_from_slice(&bytes);

  Ok(binary)
}

pub(crate) fn error(message: impl Into<String>) -> Error {
  Error::Term(Box::new(message.into()))
}
