//! Small encodings (no extra crates): hex, base64 and the fingerprint of an SSH host key.

use sha2::{Digest, Sha256};
use std::fmt::Write;

pub(super) fn hex(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        // writing into a String cannot fail
        let _ = write!(text, "{byte:02x}");
    }
    text
}

pub(super) fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() & 1 == 1 || !s.is_ascii() {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| {
            s.get(i..i + 2)
                .and_then(|pair| u8::from_str_radix(pair, 16).ok())
        })
        .collect()
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub(super) fn b64_with(bytes: &[u8], pad: bool) -> String {
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        // up to three bytes in the low 24 bits, a short last chunk filled with zeros
        let mut group = [0u8; 4];
        for (slot, byte) in group.iter_mut().skip(1).zip(chunk) {
            *slot = *byte;
        }
        let bits = u32::from_be_bytes(group);
        // n bytes give n + 1 letters
        let letters = [18, 12, 6, 0]
            .into_iter()
            .take(chunk.len() + 1)
            .filter_map(|shift| {
                let [.., low] = (bits >> shift).to_be_bytes();
                // six bits: always inside the 64 letters
                B64.get(usize::from(low & 63))
            });
        text.extend(letters.map(|&letter| char::from(letter)));
        if pad {
            text.extend((chunk.len()..3).map(|_| '='));
        }
    }
    text
}

pub fn b64(b: &[u8]) -> String {
    b64_with(b, true)
}

pub fn unb64(s: &str) -> Option<Vec<u8>> {
    let s = s.trim_end_matches('=');
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0);
    for c in s.bytes() {
        let (value, _) = (0u32..).zip(B64).find(|&(_, &letter)| letter == c)?;
        acc = (acc << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            let [.., byte] = (acc >> bits).to_be_bytes();
            out.push(byte);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// `SHA256:<base64 without padding>` of the key blob of an SSH public key line ("ssh-ed25519 AAAA... comment").
pub fn fingerprint(hostkey: &str) -> Option<String> {
    let mut it = hostkey.split_whitespace();
    let kind = it.next()?;
    let blob = unb64(it.next()?)?;
    if !kind.starts_with("ssh-") && !kind.starts_with("ecdsa-") {
        return None;
    }
    if blob.is_empty() {
        return None;
    }
    Some(format!(
        "SHA256:{}",
        b64_with(&Sha256::digest(&blob), false)
    ))
}
