//! The two doors of the server that made a code: the claim of an offer and the push for a receive code.

use super::{Entry, Inner, Keys, Kind, Random, Store, Taken};
use super::{fingerprint, open_answer, seal_answer, valid_name};
use serde_json::{Value, json};

/// Error names of the refusal shape (docs/errors.md): one answer for unknown, expired and used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Unknown,
    Rate,
    Unavailable,
}

impl Refusal {
    pub fn name(self) -> &'static str {
        match self {
            Refusal::Unknown => "code.unknown",
            Refusal::Rate => "code.rate",
            Refusal::Unavailable => "code.unavailable",
        }
    }
    /// `{"v":1,"error":"code.unknown"}`
    pub fn body(self) -> Value {
        json!({"v": 1, "error": self.name()})
    }
}

/// The outside world of a door: the account work (shell, remote.sh), the mount and the event log.
pub trait Host {
    /// Make or reuse the login for `server`, set a new password, READ on `share`. `Err(Refusal::Unknown)` for a name another server owns (Q4).
    fn grant(
        &self,
        server: &str,
        share: &str,
        fingerprint: &str,
        bound: bool,
    ) -> Result<Inner, Refusal>;
    /// Store what a server pushed and mount it.
    fn mount(&self, inner: &Inner) -> Result<(), Refusal>;
    /// Write one event (never a code, id, key or password in the payload).
    fn event(&self, kind: &str, subject: &str, level: &str, payload: &Value);
}

/// What the HTTP handler sends: status class as the error name (or none) and the body.
#[derive(Debug)]
pub struct Reply {
    pub error: Option<Refusal>,
    pub body: Value,
}

fn refuse(r: Refusal) -> Reply {
    Reply {
        error: Some(r),
        body: r.body(),
    }
}

fn take_or_refuse(
    store: &Store<'_>,
    host: &dyn Host,
    kind: Kind,
    id: &str,
    source: &str,
) -> Result<Entry, Reply> {
    match store.take(kind, id, source) {
        Ok(Taken::Found(e)) => Ok(e),
        Ok(Taken::RateLimited) => {
            host.event(
                "remote.claim.refused",
                source,
                "warn",
                &json!({"why": "rate"}),
            );
            Err(refuse(Refusal::Rate))
        }
        Ok(Taken::Unknown { burned }) => {
            host.event(
                "remote.claim.refused",
                source,
                "warn",
                &json!({"why": "unknown"}),
            );
            if burned {
                host.event("remote.codes.burned", "-", "warn", &json!({}));
            }
            Err(refuse(Refusal::Unknown))
        }
        Err(_) => Err(refuse(Refusal::Unavailable)),
    }
}

fn is_id(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The giving side (D5): `body` is the request exactly as it came (it is the associated data of the box), `source` the caller's address.
pub fn claim(
    store: &Store<'_>,
    host: &dyn Host,
    rng: &mut dyn Random,
    body: &[u8],
    source: &str,
) -> Reply {
    let req: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return refuse(Refusal::Unknown),
    };
    let id = req.get("id").and_then(Value::as_str).unwrap_or("");
    let name = req.get("name").and_then(Value::as_str).unwrap_or("");
    let hostkey = req.get("hostkey").and_then(Value::as_str).unwrap_or("");
    if req.get("v") != Some(&json!(1)) || !is_id(id) {
        return refuse(Refusal::Unknown);
    }
    // the rate limit and the lookup come before the other fields are judged: a bad name must not be a way to probe codes
    let entry = match take_or_refuse(store, host, Kind::Offer, id, source) {
        Ok(e) => e,
        Err(r) => return r,
    };
    let bound = entry.server != "-";
    let server = if bound { entry.server.as_str() } else { name };
    let fp = fingerprint(hostkey);
    if !valid_name(server) || fp.is_none() {
        host.event(
            "remote.claim.refused",
            source,
            "warn",
            &json!({"why": "request"}),
        );
        return refuse(Refusal::Unknown);
    }
    let fp = fp.unwrap_or_default();
    let inner = match host.grant(server, &entry.share, &fp, bound) {
        Ok(i) => i,
        Err(r) => {
            host.event(
                "remote.claim.refused",
                server,
                "warn",
                &json!({"why": r.name()}),
            );
            return refuse(r);
        }
    };
    let Some(keys) = Keys::from_stored(&entry.id, &entry.key) else {
        return refuse(Refusal::Unavailable);
    };
    match seal_answer(&keys, rng, body, inner.to_json().to_string().as_bytes()) {
        Ok(b) => {
            host.event(
                "remote.claimed",
                server,
                "info",
                &json!({"server": server, "share": entry.share, "fingerprint": fp}),
            );
            Reply {
                error: None,
                body: b,
            }
        }
        Err(_) => refuse(Refusal::Unavailable),
    }
}

/// The receiving side of the reverse direction: another server pushes `{"v":1,"id","nonce","box"}` for a receive code made here.
pub fn accept(store: &Store<'_>, host: &dyn Host, body: &[u8], source: &str) -> Reply {
    let req: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return refuse(Refusal::Unknown),
    };
    let id = req.get("id").and_then(Value::as_str).unwrap_or("");
    if !is_id(id) || req.get("v") != Some(&json!(1)) {
        return refuse(Refusal::Unknown);
    }
    let entry = match take_or_refuse(store, host, Kind::Receive, id, source) {
        Ok(e) => e,
        Err(r) => return r,
    };
    let inner = Keys::from_stored(&entry.id, &entry.key)
        .and_then(|k| open_answer(&k, id.as_bytes(), &req))
        .and_then(|p| serde_json::from_slice::<Value>(&p).ok())
        .and_then(|v| Inner::from_json(&v));
    let Some(inner) = inner else {
        host.event(
            "remote.claim.refused",
            source,
            "warn",
            &json!({"why": "box"}),
        );
        return refuse(Refusal::Unknown);
    };
    match host.mount(&inner) {
        Ok(()) => {
            host.event(
                "remote.claimed",
                &inner.server,
                "info",
                &json!({"server": inner.server, "share": inner.share, "host": inner.host}),
            );
            Reply {
                error: None,
                body: json!({"v": 1, "ok": true}),
            }
        }
        Err(r) => {
            host.event(
                "remote.claim.refused",
                &inner.server,
                "warn",
                &json!({"why": r.name()}),
            );
            refuse(r)
        }
    }
}
