use rlibphonenumber::{PHONE_NUMBER_UTIL, PhoneNumberFormat};
use rustler::{Error, NifResult, Term};

use crate::encoding::decode_string;

/// Parse an E.164-formatted phone number, validate it against libphonenumber's
/// metadata, and return the canonical E.164 form.
///
/// The input must be in international format (leading `+` and country code);
/// no default region is assumed, so ambiguous national-only inputs are
/// rejected. Returns `{:error, reason}` for parse failure or an invalid
/// number.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn phone_normalize_e164(phone: Term<'_>) -> NifResult<String> {
  let phone = decode_string(phone, "phone")?;

  let parsed = PHONE_NUMBER_UTIL
    .parse(&phone)
    .map_err(|error| Error::Term(Box::new(format!("invalid phone number: {error}"))))?;

  if !PHONE_NUMBER_UTIL.is_valid_number(&parsed) {
    return Err(Error::Term(Box::new(
      "invalid phone number: not a valid number".to_string(),
    )));
  }

  Ok(
    PHONE_NUMBER_UTIL
      .format(&parsed, PhoneNumberFormat::E164)
      .into_owned(),
  )
}
