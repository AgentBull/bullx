use argon2::Argon2;
use argon2::password_hash::{
  Error as PhcError, PasswordHash, PasswordHasher, PasswordVerifier, SaltString,
};
use rand::rngs::SysRng;
use rand::{RngExt, SeedableRng};
use rustler::types::binary::Binary;
use rustler::{Error, NifResult, Term};

/// Number of random bytes used to seed the per-hash salt.
/// 16 bytes matches the recommendation in RFC 9106 §3.1.
const SALT_LEN: usize = 16;

/// Hash a password with Argon2id and return a PHC string.
/// Salt is generated from the OS RNG; parameters are the OWASP-recommended defaults.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn argon2_hash(password: Term<'_>) -> NifResult<String> {
  let password = decode_binary(password, "password")?;
  let salt = generate_salt()?;

  Argon2::default()
    .hash_password(password.as_slice(), &salt)
    .map(|hash| hash.to_string())
    .map_err(|error| Error::Term(Box::new(format!("failed to hash password: {error}"))))
}

/// Verify a password against a PHC string.
/// Returns `true` on match, `false` on mismatch, and an error tuple if the
/// PHC string itself is malformed.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn argon2_verify(password: Term<'_>, phc: Term<'_>) -> NifResult<bool> {
  let password = decode_binary(password, "password")?;
  let phc = decode_string(phc, "phc")?;
  let parsed = PasswordHash::new(&phc)
    .map_err(|error| Error::Term(Box::new(format!("invalid phc string: {error}"))))?;

  match Argon2::default().verify_password(password.as_slice(), &parsed) {
    Ok(()) => Ok(true),
    Err(PhcError::Password) => Ok(false),
    Err(error) => Err(Error::Term(Box::new(format!(
      "verification failed: {error}"
    )))),
  }
}

fn generate_salt() -> NifResult<SaltString> {
  let mut sys_rng = SysRng;
  let bytes = rand_chacha::ChaCha20Rng::try_from_rng(&mut sys_rng)
    .map_err(|error| Error::Term(Box::new(format!("failed to initialize rng: {error}"))))?
    .random::<[u8; SALT_LEN]>();

  SaltString::encode_b64(&bytes)
    .map_err(|error| Error::Term(Box::new(format!("failed to encode salt: {error}"))))
}

fn decode_binary<'a>(term: Term<'a>, field: &str) -> NifResult<Binary<'a>> {
  if !term.is_binary() {
    return Err(Error::Term(Box::new(format!("{field} must be a binary"))));
  }

  Binary::from_term(term).map_err(|_| Error::Term(Box::new(format!("{field} must be a binary"))))
}

fn decode_string(term: Term<'_>, field: &str) -> NifResult<String> {
  term
    .decode()
    .map_err(|_| Error::Term(Box::new(format!("{field} must be a string"))))
}

#[cfg(test)]
mod tests {
  use super::*;

  fn hash(password: &[u8]) -> String {
    let salt = generate_salt().unwrap();
    Argon2::default()
      .hash_password(password, &salt)
      .unwrap()
      .to_string()
  }

  fn verify(password: &[u8], phc: &str) -> Result<bool, PhcError> {
    let parsed = PasswordHash::new(phc)?;
    match Argon2::default().verify_password(password, &parsed) {
      Ok(()) => Ok(true),
      Err(PhcError::Password) => Ok(false),
      Err(error) => Err(error),
    }
  }

  #[test]
  fn hash_produces_phc_string_with_argon2id() {
    let phc = hash(b"correct horse battery staple");

    assert!(phc.starts_with("$argon2id$"));
  }

  #[test]
  fn verify_accepts_matching_password() {
    let phc = hash(b"correct horse battery staple");

    assert_eq!(verify(b"correct horse battery staple", &phc), Ok(true));
  }

  #[test]
  fn verify_rejects_wrong_password() {
    let phc = hash(b"correct horse battery staple");

    assert_eq!(verify(b"wrong password", &phc), Ok(false));
  }

  #[test]
  fn verify_returns_error_for_malformed_phc_string() {
    assert!(verify(b"anything", "not-a-phc-string").is_err());
  }
}
