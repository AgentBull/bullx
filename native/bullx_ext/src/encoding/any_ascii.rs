use any_ascii::any_ascii as transliterate;
use rustler::{NifResult, Term};

use crate::encoding::decode_string;

#[rustler::nif(schedule = "DirtyCpu")]
pub fn any_ascii(input: Term<'_>) -> NifResult<String> {
  let input = decode_string(input, "input")?;

  Ok(transliterate(&input))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn any_ascii_transliterates_accented_text() {
    assert_eq!(transliterate("Björk"), "Bjork");
  }
}
