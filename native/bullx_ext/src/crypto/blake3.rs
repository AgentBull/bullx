use hex::{FromHex, ToHex};
use rand::rngs::SysRng;
use rand::{RngExt, SeedableRng};
use rustler::types::binary::Binary;
use rustler::{Error, NifResult, Term};

const GENERATE_KEY_CONTEXT: &str = "[extra=generateKey()]";

/// Computes a fixed-length fingerprint of a binary.
/// Suitable for most use cases other than hashing passwords.
/// The optional salt must be a 32-byte hex string.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn generic_hash(data: Term<'_>, salt: Option<String>) -> NifResult<String> {
  let input = decode_input(data)?;
  blake3_hash_hex(input.as_slice(), salt)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn bs58_hash(data: Term<'_>, salt: Option<String>) -> NifResult<String> {
  let input = decode_input(data)?;
  blake3_hash_bs58(input.as_slice(), salt)
}

/// Derive a new key from a master key.
/// `extra_context` does not have to be secret and can have low entropy.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn derive_key(
  key_seed: Term<'_>,
  sub_key_id: String,
  extra_context: Option<String>,
) -> NifResult<String> {
  let ctx = gen_context(&sub_key_id, extra_context);
  let seed = decode_input(key_seed)?;

  Ok(blake3::derive_key(&ctx, seed.as_slice()).encode_hex::<String>())
}

/// Generate context for key derivation.
/// `sub_key_id` is used verbatim and remains case-sensitive.
fn gen_context(sub_key_id: &str, extra_context: Option<String>) -> String {
  let sub_key = format!("[subKeyId={sub_key_id}]");

  match extra_context {
    Some(context) => format!("{sub_key} [extra={context}]"),
    None => sub_key,
  }
}

/// Generate a new master key.
/// Returns a hex-encoded string.
#[rustler::nif]
pub fn generate_key() -> NifResult<String> {
  let mut sys_rng = SysRng;
  let seed = rand_chacha::ChaCha12Rng::try_from_rng(&mut sys_rng)
    .map_err(|error| Error::Term(Box::new(format!("failed to initialize rng: {error}"))))?
    .random::<[u8; blake3::KEY_LEN]>();

  Ok(blake3::derive_key(GENERATE_KEY_CONTEXT, &seed).encode_hex::<String>())
}

fn decode_input<'a>(term: Term<'a>) -> NifResult<Binary<'a>> {
  term.decode_as_binary()
}

fn blake3_hash_hex(input: &[u8], salt: Option<String>) -> NifResult<String> {
  match salt {
    Some(salt) => {
      let key = parse_salt(&salt)?;
      Ok(blake3::keyed_hash(&key, input).to_hex().to_string())
    }
    None => Ok(blake3::hash(input).to_hex().to_string()),
  }
}

fn blake3_hash_bs58(input: &[u8], salt: Option<String>) -> NifResult<String> {
  match salt {
    Some(salt) => {
      let key = parse_salt(&salt)?;
      Ok(bs58::encode(blake3::keyed_hash(&key, input).as_bytes()).into_string())
    }
    None => Ok(bs58::encode(blake3::hash(input).as_bytes()).into_string()),
  }
}

fn parse_salt(salt: &str) -> NifResult<[u8; blake3::KEY_LEN]> {
  <[u8; blake3::KEY_LEN]>::from_hex(salt)
    .map_err(|error| Error::Term(Box::new(format!("invalid salt: {error}"))))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn gen_context_formats_sub_key_and_extra_context() {
    assert_eq!(gen_context("7", None), "[subKeyId=7]");
    assert_eq!(
      gen_context("tenant-A", Some("scope-a".to_owned())),
      "[subKeyId=tenant-A] [extra=scope-a]"
    );
  }

  #[test]
  fn gen_context_preserves_case() {
    assert_eq!(gen_context("UserKey", None), "[subKeyId=UserKey]");
    assert_eq!(gen_context("userkey", None), "[subKeyId=userkey]");
    assert_ne!(gen_context("UserKey", None), gen_context("userkey", None));
  }

  #[test]
  fn gen_context_supports_numeric_strings() {
    assert_eq!(
      gen_context("007", Some("tenant-a".to_owned())),
      "[subKeyId=007] [extra=tenant-a]"
    );
  }

  #[test]
  fn generic_hash_uses_expected_hex_encoding() {
    let hash = blake3_hash_hex(b"bullx", None).unwrap();

    assert_eq!(hash, blake3::hash(b"bullx").to_hex().to_string());
  }

  #[test]
  fn bs58_hash_uses_expected_bs58_encoding() {
    let hash = blake3_hash_bs58(b"bullx", None).unwrap();

    assert_eq!(
      hash,
      bs58::encode(blake3::hash(b"bullx").as_bytes()).into_string()
    );
  }
}
