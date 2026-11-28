//! The values both sides derive from a code, and the box sealed with them (docs/PLAN-remote-shares.md D4).

use super::Random;
use super::encoding::{b64, hex, unb64, unhex};
use crate::{Error, Result};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use serde_json::{Value, json};
use sha2::Sha256;

/// The two values both sides derive from the code (HKDF-SHA256, empty salt): the id is sent, the key never.
pub struct Keys {
    pub id: String,
    /// None only when HKDF gave no output (see `expand`): then nothing is sealed or opened.
    key: Option<[u8; 32]>,
}

/// The id only: the key is never printed.
impl std::fmt::Debug for Keys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Keys")
            .field("id", &self.id)
            .field("key", &"***")
            .finish()
    }
}

/// 32 bytes of HKDF-SHA256 over the code. HKDF refuses only an output above 8160 bytes, so this is never None; the caller still gets no
/// bytes rather than wrong ones.
fn expand(norm: &str, info: &str) -> Option<[u8; 32]> {
    let mut out = [0u8; 32];
    Hkdf::<Sha256>::new(None, norm.as_bytes())
        .expand(info.as_bytes(), &mut out)
        .ok()?;
    Some(out)
}

pub fn derive(norm: &str) -> Keys {
    Keys {
        // an empty id matches no code: a claim and a push need 64 hex digits
        id: expand(norm, "hobnix remote v1 id")
            .map(|bytes| hex(&bytes))
            .unwrap_or_default(),
        key: expand(norm, "hobnix remote v1 key"),
    }
}

impl Keys {
    pub(super) fn from_stored(id: &str, key_hex: &str) -> Option<Keys> {
        let k = unhex(key_hex)?;
        Some(Keys {
            id: id.to_string(),
            key: Some(k.try_into().ok()?),
        })
    }

    /// The key as the code store keeps it.
    pub(super) fn key_hex(&self) -> Option<String> {
        self.key.map(|key| hex(&key))
    }
}

/// ChaCha20-Poly1305 with the derived key; `aad` is authenticated, not sent inside.
pub fn seal(keys: &Keys, nonce: &[u8; 12], aad: &[u8], plain: &[u8]) -> Result<Vec<u8>> {
    let failed = || Error::Failed("cannot seal".into());
    let key = keys.key.as_ref().ok_or_else(failed)?;
    ChaCha20Poly1305::new(Key::from_slice(key))
        .encrypt(Nonce::from_slice(nonce), Payload { msg: plain, aad })
        .map_err(|_| failed())
}

pub fn open(keys: &Keys, nonce: &[u8], aad: &[u8], boxed: &[u8]) -> Option<Vec<u8>> {
    if nonce.len() != 12 {
        return None;
    }
    ChaCha20Poly1305::new(Key::from_slice(keys.key.as_ref()?))
        .decrypt(Nonce::from_slice(nonce), Payload { msg: boxed, aad })
        .ok()
}

/// `{"v":1,"nonce":..,"box":..}`; `aad` is the request body of the claim (or the id of a push).
pub fn seal_answer(keys: &Keys, rng: &mut dyn Random, aad: &[u8], inner: &[u8]) -> Result<Value> {
    let mut nonce = [0u8; 12];
    rng.fill(&mut nonce)?;
    let boxed = seal(keys, &nonce, aad, inner)?;
    Ok(json!({"v": 1, "nonce": b64(&nonce), "box": b64(&boxed)}))
}

pub fn open_answer(keys: &Keys, aad: &[u8], answer: &Value) -> Option<Vec<u8>> {
    if answer.get("v")? != 1 {
        return None;
    }
    let nonce = unb64(answer.get("nonce")?.as_str()?)?;
    let boxed = unb64(answer.get("box")?.as_str()?)?;
    open(keys, &nonce, aad, &boxed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn without_a_key_nothing_is_sealed_or_opened() {
        let whole = derive("ABCDEFGHJKLMNPQR");
        let boxed = seal(&whole, &[0u8; 12], b"aad", b"plain").unwrap();
        let empty = Keys {
            id: whole.id.clone(),
            key: None,
        };
        assert_eq!(
            seal(&empty, &[0u8; 12], b"aad", b"plain"),
            Err(Error::Failed("cannot seal".into()))
        );
        assert!(open(&empty, &[0u8; 12], b"aad", &boxed).is_none());
        assert!(empty.key_hex().is_none());
    }
}
