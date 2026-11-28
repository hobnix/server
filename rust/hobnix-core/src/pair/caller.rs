//! The calling side: the server where the code is typed.

use super::{Inner, Random, derive, fingerprint, open_answer, seal_answer, valid_name};
use crate::{Error, Result};
use serde_json::{Value, json};

/// The claim request body for a typed code (`normalize` it first).
pub fn claim_request(norm: &str, name: &str, hostkey: &str) -> Result<String> {
    if !valid_name(name) {
        return Err(Error::Refused(
            "the server name of this machine is not valid".into(),
        ));
    }
    if fingerprint(hostkey).is_none() {
        return Err(Error::Refused("no SSH host key of this machine".into()));
    }
    Ok(json!({"v": 1, "id": derive(norm)?.id, "name": name, "hostkey": hostkey}).to_string())
}

/// Open the answer of a claim; None for a box that does not open (wrong code, fake server, changed request), and without keys.
pub fn open_claim(norm: &str, request: &[u8], answer: &Value) -> Option<Value> {
    let keys = derive(norm).ok()?;
    let plain = open_answer(&keys, request, answer)?;
    let v: Value = serde_json::from_slice(&plain).ok()?;
    Inner::from_json(&v)?;
    Some(v)
}

/// The push body for a typed receive code: the inner JSON in a box, the id as associated data.
pub fn push_body(norm: &str, inner: &Inner, rng: &mut dyn Random) -> Result<String> {
    let keys = derive(norm)?;
    let mut body = seal_answer(
        &keys,
        rng,
        keys.id.as_bytes(),
        inner.to_json().to_string().as_bytes(),
    )?;
    body.as_object_mut()
        .ok_or_else(|| Error::Failed("cannot seal".into()))?
        .insert("id".into(), Value::String(keys.id));
    Ok(body.to_string())
}
