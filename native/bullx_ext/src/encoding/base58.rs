use rustler::{NifResult, OwnedBinary, Term};

use crate::encoding::{binary_from_vec, decode_binary, decode_string, error};

#[rustler::nif(schedule = "DirtyCpu")]
pub fn base58_encode(input: Term<'_>) -> NifResult<String> {
  let input = decode_binary(input, "input")?;

  Ok(encode_base58(input.as_slice()))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn base58_decode(input: Term<'_>) -> NifResult<OwnedBinary> {
  let input = decode_string(input, "input")?;

  decode_base58(&input).and_then(binary_from_vec)
}

fn encode_base58(input: &[u8]) -> String {
  bs58::encode(input).into_string()
}

fn decode_base58(input: &str) -> NifResult<Vec<u8>> {
  bs58::decode(input)
    .into_vec()
    .map_err(|decode_error| error(decode_error.to_string()))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn base58_round_trip_preserves_binary_payload() {
    let payload = [0_u8, 255, 1, 2, 3];
    let encoded = encode_base58(&payload);
    let decoded = decode_base58(&encoded).unwrap();

    assert_eq!(decoded, payload);
  }

  #[test]
  fn base58_decode_returns_error_for_invalid_input() {
    assert!(decode_base58("0OIl").is_err());
  }
}
