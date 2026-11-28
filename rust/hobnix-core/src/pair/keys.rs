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
    pub(super) key: [u8; 32],
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

/// 32 bytes of HKDF-SHA256 over the code. HKDF refuses only an output above 8160 bytes.
fn expand(norm: &str, info: &str) -> Result<[u8; 32]> {
    let mut out = [0u8; 32];
    Hkdf::<Sha256>::new(None, norm.as_bytes())
        .expand(info.as_bytes(), &mut out)
        .map_err(|_| Error::Failed("cannot derive the keys of the code".into()))?;
    Ok(out)
}

/// Fails only when HKDF gives no output.
pub fn derive(norm: &str) -> Result<Keys> {
    Ok(Keys {
        id: hex(&expand(norm, "hobnix remote v1 id")?),
        key: expand(norm, "hobnix remote v1 key")?,
    })
}

impl Keys {
    pub(super) fn from_stored(id: &str, key_hex: &str) -> Option<Keys> {
        let k = unhex(key_hex)?;
        Some(Keys {
            id: id.to_string(),
            key: k.try_into().ok()?,
        })
    }
}

/// ChaCha20-Poly1305 with the derived key; `aad` is authenticated, not sent inside.
pub fn seal(keys: &Keys, nonce: &[u8; 12], aad: &[u8], plain: &[u8]) -> Result<Vec<u8>> {
    ChaCha20Poly1305::new(Key::from_slice(&keys.key))
        .encrypt(Nonce::from_slice(nonce), Payload { msg: plain, aad })
        .map_err(|_| Error::Failed("cannot seal".into()))
}

pub fn open(keys: &Keys, nonce: &[u8], aad: &[u8], boxed: &[u8]) -> Option<Vec<u8>> {
    if nonce.len() != 12 {
        return None;
    }
    ChaCha20Poly1305::new(Key::from_slice(&keys.key))
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
