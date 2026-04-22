use base64_simd::URL_SAFE_NO_PAD;
use rustler::{NifResult, OwnedBinary, Term};

use crate::encoding::{binary_from_vec, decode_binary, decode_string, error};

#[rustler::nif(schedule = "DirtyCpu")]
pub fn base64_url_safe_encode(input: Term<'_>) -> NifResult<String> {
  let input = decode_binary(input, "input")?;

  Ok(url_safe_encode(input.as_slice()))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn base64_url_safe_decode(input: Term<'_>) -> NifResult<OwnedBinary> {
  let input = decode_string(input, "input")?;

  url_safe_decode(&input).and_then(binary_from_vec)
}

fn url_safe_encode(input: &[u8]) -> String {
  URL_SAFE_NO_PAD.encode_to_string(input)
}

fn url_safe_decode(input: &str) -> NifResult<Vec<u8>> {
  URL_SAFE_NO_PAD
    .decode_to_vec(input)
    .map_err(|decode_error| error(decode_error.to_string()))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn url_safe_base64_round_trip_preserves_binary_payload() {
    let payload = [0_u8, 255, 1, 2, 3];
    let encoded = url_safe_encode(&payload);
    let decoded = url_safe_decode(&encoded).unwrap();

    assert_eq!(decoded, payload);
  }

  #[test]
  fn url_safe_base64_omits_padding() {
    assert_eq!(url_safe_encode(b"bullx"), "YnVsbHg");
  }
}
