//! The code a person reads out on one server and types on the other.

use super::Random;
use crate::{Error, Result};

/// The alphabet of the setup code (`scripts/first_run.py)`: no 0 O 1 I. 32 letters, so one random byte masked with 31 is uniform.
pub const ALPHABET: &str = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
pub const CODE_LEN: usize = 16;

/// A new code, written as four groups of four.
pub fn new_code(rng: &mut dyn Random) -> Result<String> {
    let mut random = [0u8; CODE_LEN];
    rng.fill(&mut random)?;
    let mut code = String::with_capacity(CODE_LEN + 3);
    for (position, byte) in random.iter().enumerate() {
        if position > 0 && position % 4 == 0 {
            code.push('-');
        }
        let letter = ALPHABET
            .as_bytes()
            .get(usize::from(byte & 31))
            .ok_or_else(|| Error::Failed("the new code is not valid".into()))?;
        code.push(char::from(*letter));
    }
    Ok(code)
}

/// What a person types: any case, with or without dashes and spaces. None when it cannot be a code.
pub fn normalize(s: &str) -> Option<String> {
    if s.len() > 64 {
        return None;
    }
    let t: String = s
        .chars()
        .filter(|c| !matches!(c, '-' | ' ' | '\t'))
        .flat_map(char::to_uppercase)
        .collect();
    (t.len() == CODE_LEN && t.chars().all(|c| ALPHABET.contains(c))).then_some(t)
}

/// The normalized code written as four groups of four.
pub fn format_code(norm: &str) -> String {
    norm.as_bytes()
        .chunks(4)
        .map(|c| std::str::from_utf8(c).unwrap_or(""))
        .collect::<Vec<_>>()
        .join("-")
}
