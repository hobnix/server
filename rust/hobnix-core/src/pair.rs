//! Pairing of remote shares by code (docs/PLAN-remote-shares.md D3 to D6): the code, its derived id and key, the box, the code store and the rate
//! limit. The clock and the random source are parameters, so the tests need no sleeping and no real randomness. No terminal output.
#![expect(
    clippy::indexing_slicing,
    clippy::string_slice,
    clippy::cast_possible_truncation,
    clippy::format_collect,
    reason = "ratchet #1307: fixed-size codes and alphabets; to be rewritten with get() and try_from"
)]

use crate::{Error, Result, Secret};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// The alphabet of the setup code (`scripts/first_run.py)`: no 0 O 1 I. 32 letters, so one random byte masked with 31 is uniform.
pub const ALPHABET: &str = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
pub const CODE_LEN: usize = 16;
pub const MAX_OPEN: usize = 5;
pub const MAX_MINUTES: u64 = 60;
pub const DEFAULT_MINUTES: u64 = 10;
/// Failed claims per source and window before that source gets `code.rate`.
pub const RATE_FAILS: usize = 5;
pub const RATE_WINDOW: u64 = 60;
/// Failed claims of all sources in the burn window that end every open code.
pub const BURN_FAILS: usize = 20;
pub const BURN_WINDOW: u64 = 600;

/// Seconds since the epoch; a parameter so tests do not sleep.
pub trait Clock {
    fn now(&self) -> u64;
}

#[derive(Debug)]
pub struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs())
    }
}

/// Where random bytes come from; a parameter so tests are repeatable.
pub trait Random {
    fn fill(&mut self, buf: &mut [u8]) -> Result<()>;
}

#[derive(Debug)]
pub struct OsRandom;
impl Random for OsRandom {
    fn fill(&mut self, buf: &mut [u8]) -> Result<()> {
        File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(buf))
            .map_err(|_| Error::Failed("no random source".into()))
    }
}

/// A new code, written as four groups of four.
pub fn new_code(rng: &mut dyn Random) -> Result<String> {
    let mut b = [0u8; CODE_LEN];
    rng.fill(&mut b)?;
    let a = ALPHABET.as_bytes();
    let mut out = String::with_capacity(CODE_LEN + 3);
    for (i, x) in b.iter().enumerate() {
        if i > 0 && i % 4 == 0 {
            out.push('-');
        }
        out.push(a[(*x & 31) as usize] as char);
    }
    Ok(out)
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

/// The two values both sides derive from the code (HKDF-SHA256, empty salt): the id is sent, the key never.
pub struct Keys {
    pub id: String,
    key: [u8; 32],
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

fn expand(norm: &str, info: &str) -> [u8; 32] {
    let h = Hkdf::<Sha256>::new(None, norm.as_bytes());
    let mut out = [0u8; 32];
    #[expect(
        clippy::expect_used,
        reason = "HKDF-SHA256 cannot fail for a 32 byte output (the limit is 8160 bytes)"
    )]
    h.expand(info.as_bytes(), &mut out)
        .expect("32 bytes are a valid HKDF length");
    out
}

pub fn derive(norm: &str) -> Keys {
    Keys {
        id: hex(&expand(norm, "hobnix remote v1 id")),
        key: expand(norm, "hobnix remote v1 key"),
    }
}

impl Keys {
    fn from_stored(id: &str, key_hex: &str) -> Option<Keys> {
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

// ---------------------------------------------------------------- small encodings (no extra crates)

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() & 1 == 1 || !s.is_ascii() {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64_with(b: &[u8], pad: bool) -> String {
    let mut o = String::with_capacity(b.len().div_ceil(3) * 4);
    for c in b.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= c.len() {
                o.push(B64[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else if pad {
                o.push('=');
            }
        }
    }
    o
}

pub fn b64(b: &[u8]) -> String {
    b64_with(b, true)
}

pub fn unb64(s: &str) -> Option<Vec<u8>> {
    let s = s.trim_end_matches('=');
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0);
    for c in s.bytes() {
        let v = B64.iter().position(|x| *x == c)? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
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

// ---------------------------------------------------------------- the code store

/// Which door a code opens.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// This server gives a share; the other side claims it (`POST /api/remote/claim`).
    Offer,
    /// This server waits for a share another server pushes (`POST /api/remote/push`).
    Receive,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    /// The derived key in hex: never printed (see the Debug below).
    pub key: String,
    pub kind: Kind,
    /// The share, or `-` for a code that waits for any share (a receive code).
    pub share: String,
    /// The server name the code is bound to, or `-`.
    pub server: String,
    pub expires: u64,
}

/// Everything but the key (the id is sent anyway, the key never).
impl std::fmt::Debug for Entry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Entry")
            .field("id", &self.id)
            .field("key", &"***")
            .field("kind", &self.kind)
            .field("share", &self.share)
            .field("server", &self.server)
            .field("expires", &self.expires)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Fail {
    src: String,
    at: u64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct State {
    #[serde(default)]
    codes: Vec<Entry>,
    #[serde(default)]
    fails: Vec<Fail>,
}

/// A made code: the only moment the code itself exists on this server.
#[derive(Debug)]
pub struct Made {
    pub code: Secret,
    pub expires_in: u64,
}

#[derive(Debug)]
pub struct Listed {
    pub kind: Kind,
    pub share: String,
    pub server: String,
    pub expires_in: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Taken {
    Found(Entry),
    Unknown { burned: bool },
    RateLimited,
}

pub struct Store<'a> {
    path: PathBuf,
    clock: &'a dyn Clock,
}

impl std::fmt::Debug for Store<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Store")
            .field("path", &self.path)
            .field("now", &self.clock.now())
            .finish_non_exhaustive()
    }
}

impl<'a> Store<'a> {
    pub fn new(path: impl Into<PathBuf>, clock: &'a dyn Clock) -> Store<'a> {
        Store {
            path: path.into(),
            clock,
        }
    }

    fn lock(&self) -> Result<File> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)
                .map_err(|_| Error::Failed("cannot make the code folder".into()))?;
        }
        let lock_path = self.path.with_extension("lock");
        let f = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(lock_path)
            .map_err(|_| Error::Failed("cannot open the code store lock".into()))?;
        f.lock()
            .map_err(|_| Error::Failed("cannot lock the code store".into()))?;
        Ok(f)
    }

    fn read(&self) -> State {
        std::fs::read_to_string(&self.path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    fn write(&self, st: &State) -> Result<()> {
        let tmp = self.path.with_extension("new");
        let mut o = OpenOptions::new();
        o.create(true).truncate(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            o.mode(0o600);
        }
        let text = serde_json::to_string(st)
            .map_err(|_| Error::Failed("cannot write the code store".into()))?;
        o.open(&tmp)
            .and_then(|mut f| f.write_all(text.as_bytes()).and_then(|()| f.sync_all()))
            .and_then(|()| std::fs::rename(&tmp, &self.path))
            .map_err(|_| Error::Failed("cannot write the code store".into()))
    }

    /// Lock, read, drop what ran out, run `f`, write. One writer at a time, shared by HTTP and SSH.
    fn update<T>(&self, f: impl FnOnce(&mut State, u64) -> T) -> Result<T> {
        let _lock = self.lock()?;
        let now = self.clock.now();
        let mut st = self.read();
        st.codes.retain(|c| c.expires > now);
        st.fails.retain(|x| x.at + BURN_WINDOW > now);
        let out = f(&mut st, now);
        self.write(&st)?;
        Ok(out)
    }

    /// Make a code and keep only the derived values. Refused when 5 are open or the life time is out of range.
    pub fn make(
        &self,
        kind: Kind,
        share: &str,
        server: &str,
        minutes: u64,
        rng: &mut dyn Random,
    ) -> Result<Made> {
        if minutes == 0 || minutes > MAX_MINUTES {
            return Err(Error::Refused(format!(
                "the code lives 1 to {MAX_MINUTES} minutes"
            )));
        }
        let code = new_code(rng)?;
        let norm =
            normalize(&code).ok_or_else(|| Error::Failed("the new code is not valid".into()))?;
        let keys = derive(&norm);
        let made = self.update(|st, now| {
            if st.codes.len() >= MAX_OPEN {
                return Err(Error::Refused(format!(
                    "{MAX_OPEN} codes are open already (hs remote codes --cancel ends them)"
                )));
            }
            st.codes.push(Entry {
                id: keys.id.clone(),
                key: hex(&keys.key),
                kind,
                share: share.to_string(),
                server: server.to_string(),
                expires: now + minutes * 60,
            });
            Ok(minutes * 60)
        })??;
        Ok(Made {
            code: Secret::new(code),
            expires_in: made,
        })
    }

    pub fn list(&self) -> Result<Vec<Listed>> {
        self.update(|st, now| {
            st.codes
                .iter()
                .map(|c| Listed {
                    kind: c.kind,
                    share: c.share.clone(),
                    server: c.server.clone(),
                    expires_in: c.expires.saturating_sub(now),
                })
                .collect()
        })
    }

    /// End every open code; how many there were.
    pub fn cancel_all(&self) -> Result<usize> {
        self.update(|st, _| {
            let n = st.codes.len();
            st.codes.clear();
            n
        })
    }

    /// Look up `id` for one claim from `source` and remove the code in the same step (one use). A miss counts as a failure: 5 from one source
    /// in a minute end that source's tries, 20 from all sources in 10 minutes end every open code.
    pub fn take(&self, kind: Kind, id: &str, source: &str) -> Result<Taken> {
        self.update(|st, now| {
            let mine = st
                .fails
                .iter()
                .filter(|x| x.src == source && x.at + RATE_WINDOW > now)
                .count();
            if mine >= RATE_FAILS {
                return Taken::RateLimited;
            }
            // every code is compared, in constant time: the time says nothing about which id is close
            let mut hit = None;
            for (i, c) in st.codes.iter().enumerate() {
                if ct_eq(c.id.as_bytes(), id.as_bytes()) && c.kind == kind {
                    hit = Some(i);
                }
            }
            if let Some(i) = hit {
                return Taken::Found(st.codes.remove(i));
            }
            st.fails.push(Fail {
                src: source.to_string(),
                at: now,
            });
            let burned = st.fails.len() >= BURN_FAILS;
            if burned {
                st.codes.clear();
                st.fails.clear();
            }
            Taken::Unknown { burned }
        })
    }
}

// ---------------------------------------------------------------- the two doors (A: claim, B: accept a push)

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

/// What the other side gets (or hands over) inside the box. Debug is safe: the password is a [`Secret`].
#[derive(Debug)]
pub struct Inner {
    pub server: String,
    pub host: String,
    pub share: String,
    pub login: String,
    pub domain: String,
    pub password: Secret,
    pub hostkey: String,
}

impl Inner {
    pub fn to_json(&self) -> Value {
        json!({"server": self.server, "host": self.host, "share": self.share, "login": self.login,
               "domain": self.domain, "password": self.password.expose(), "hostkey": self.hostkey})
    }

    pub fn from_json(v: &Value) -> Option<Inner> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        Some(Inner {
            server: s("server").filter(|x| valid_name(x))?,
            host: s("host").filter(|x| valid_host(x))?,
            share: s("share").filter(|x| valid_share(x))?,
            login: s("login").filter(|x| valid_login(x))?,
            domain: s("domain").filter(|x| x.is_empty() || valid_login(x))?,
            password: Secret::new(s("password").filter(|x| !x.is_empty() && x.len() <= 256)?),
            hostkey: s("hostkey").unwrap_or_default(),
        })
    }
}

fn word_ok(s: &str, max: usize, extra: &str) -> bool {
    let mut it = s.chars();
    s.len() <= max
        && it.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && it.all(|c| c.is_ascii_alphanumeric() || extra.contains(c))
}

/// The host name of a server: lower case, digits and dashes, at most 20 (`^[a-z0-9][a-z0-9-]{0,19}$`).
pub fn valid_name(s: &str) -> bool {
    word_ok(s, 20, "-") && !s.chars().any(|c| c.is_ascii_uppercase())
}
pub fn valid_share(s: &str) -> bool {
    word_ok(s, 64, "._-")
}
pub fn valid_login(s: &str) -> bool {
    word_ok(s, 64, "._-")
}
pub fn valid_host(s: &str) -> bool {
    word_ok(s, 253, "._:-")
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
    ) -> std::result::Result<Inner, Refusal>;
    /// Store what a server pushed and mount it.
    fn mount(&self, inner: &Inner) -> std::result::Result<(), Refusal>;
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
) -> std::result::Result<Entry, Reply> {
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

/// Equal without stopping at the first difference.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    let mut d = (a.len() ^ b.len()) as u8;
    for (x, y) in a.iter().zip(b.iter()) {
        d |= x ^ y;
    }
    d == 0
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

// ---------------------------------------------------------------- the calling side (the server that types the code)

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
    Ok(json!({"v": 1, "id": derive(norm).id, "name": name, "hostkey": hostkey}).to_string())
}

/// Open the answer of a claim; None for a box that does not open (wrong code, fake server, changed request).
pub fn open_claim(norm: &str, request: &[u8], answer: &Value) -> Option<Value> {
    let plain = open_answer(&derive(norm), request, answer)?;
    let v: Value = serde_json::from_slice(&plain).ok()?;
    Inner::from_json(&v)?;
    Some(v)
}

/// The push body for a typed receive code: the inner JSON in a box, the id as associated data.
pub fn push_body(norm: &str, inner: &Inner, rng: &mut dyn Random) -> Result<String> {
    let keys = derive(norm);
    let b = seal_answer(
        &keys,
        rng,
        keys.id.as_bytes(),
        inner.to_json().to_string().as_bytes(),
    )?;
    let mut o = b;
    o["id"] = Value::String(keys.id);
    Ok(o.to_string())
}

pub fn default_store_path() -> PathBuf {
    std::env::var_os("HS_REMOTE_CODES")
        .filter(|v| !v.is_empty())
        .map_or_else(
            || Path::new("/run/hs/remote-codes.json").to_path_buf(),
            PathBuf::from,
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    struct FakeClock(Cell<u64>);
    impl Clock for FakeClock {
        fn now(&self) -> u64 {
            self.0.get()
        }
    }

    /// Counts up: repeatable "random" bytes.
    struct Counter(u8);
    impl Random for Counter {
        fn fill(&mut self, buf: &mut [u8]) -> Result<()> {
            for b in buf.iter_mut() {
                self.0 = self.0.wrapping_mul(31).wrapping_add(7);
                *b = self.0;
            }
            Ok(())
        }
    }

    struct FakeHost {
        events: RefCell<Vec<(String, String)>>,
        taken: bool,
        down: bool,
    }
    impl FakeHost {
        fn new() -> FakeHost {
            FakeHost {
                events: RefCell::new(vec![]),
                taken: false,
                down: false,
            }
        }
        fn kinds(&self) -> Vec<String> {
            self.events.borrow().iter().map(|e| e.0.clone()).collect()
        }
    }
    impl Host for FakeHost {
        fn grant(
            &self,
            server: &str,
            share: &str,
            _fp: &str,
            _bound: bool,
        ) -> std::result::Result<Inner, Refusal> {
            if self.taken {
                return Err(Refusal::Unknown);
            }
            if self.down {
                return Err(Refusal::Unavailable);
            }
            Ok(Inner {
                server: "alpha".into(),
                host: "alpha.local".into(),
                share: share.into(),
                login: format!("remote-{server}"),
                domain: "HOME".into(),
                password: Secret::new("pw-secret-123"),
                hostkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA".into(),
            })
        }
        fn mount(&self, inner: &Inner) -> std::result::Result<(), Refusal> {
            if self.down {
                Err(Refusal::Unavailable)
            } else {
                assert_eq!(inner.password.expose(), "pw-secret-123");
                Ok(())
            }
        }
        fn event(&self, kind: &str, subject: &str, _level: &str, payload: &Value) {
            let t = payload.to_string();
            assert!(!t.contains("pw-secret"), "no secret in an event");
            self.events.borrow_mut().push((kind.into(), subject.into()));
        }
    }

    const KEY: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("hobnix-pair-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d.join("codes.json")
    }

    #[test]
    fn code_alphabet_and_shape() {
        let c = new_code(&mut Counter(1)).unwrap();
        assert_eq!(c.len(), 19);
        assert!(normalize(&c).is_some());
        assert_eq!(format_code(&normalize(&c).unwrap()), c);
        assert_eq!(
            normalize("abcd efgh-jklm npqr"),
            Some("ABCDEFGHJKLMNPQR".into())
        );
        assert_eq!(normalize("ABCD-EFGH-JKLM-NPQ0"), None); // 0 is not in the alphabet
        assert_eq!(normalize("ABCD"), None);
        assert_eq!(normalize(&"A".repeat(100)), None);
    }

    #[test]
    fn derive_is_stable_and_apart() {
        let a = derive("ABCDEFGHJKLMNPQR");
        let b = derive("ABCDEFGHJKLMNPQR");
        assert_eq!(a.id, b.id);
        assert_eq!(a.id.len(), 64);
        assert_ne!(hex(&a.key), a.id);
        assert_ne!(derive("ABCDEFGHJKLMNPQS").id, a.id);
    }

    #[test]
    fn hkdf_known_answer() {
        // RFC 5869 test case 3 (no salt, no info) pins the HKDF-SHA256 construction used here
        let ikm = [0x0bu8; 22];
        let h = Hkdf::<Sha256>::new(None, &ikm);
        let mut okm = [0u8; 42];
        h.expand(b"", &mut okm).unwrap();
        assert_eq!(
            hex(&okm),
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
        );
    }

    #[test]
    fn base64_roundtrip_and_fingerprint() {
        for n in 0..9u8 {
            let v: Vec<u8> = (0..n).map(|x| x.wrapping_mul(37)).collect();
            assert_eq!(unb64(&b64(&v)).unwrap(), v);
        }
        assert_eq!(b64(b"foobar"), "Zm9vYmFy");
        assert_eq!(b64(b"fooba"), "Zm9vYmE=");
        let fp = fingerprint(KEY).unwrap();
        assert!(fp.starts_with("SHA256:") && !fp.contains('='));
        assert!(fingerprint("nonsense").is_none());
    }

    #[test]
    fn box_opens_only_with_key_and_same_aad() {
        let k = derive("ABCDEFGHJKLMNPQR");
        let ans = seal_answer(&k, &mut Counter(3), b"request", b"{\"a\":1}").unwrap();
        assert_eq!(open_answer(&k, b"request", &ans).unwrap(), b"{\"a\":1}");
        assert!(open_answer(&k, b"other", &ans).is_none());
        assert!(open_answer(&derive("ABCDEFGHJKLMNPQS"), b"request", &ans).is_none());
        assert!(!ans.to_string().contains("\"a\":1"));
    }

    #[test]
    fn debug_does_not_show_the_derived_key() {
        let clock = FakeClock(Cell::new(1000));
        let st = Store::new(tmp("debug"), &clock);
        let m = st
            .make(Kind::Offer, "media", "-", 10, &mut Counter(1))
            .unwrap();
        let keys = derive(&normalize(m.code.expose()).unwrap());
        let key = hex(&keys.key);
        let taken = st.take(Kind::Offer, &keys.id, "10.0.0.2").unwrap();
        let Taken::Found(entry) = &taken else {
            panic!("the code was not found");
        };
        assert_eq!(entry.key, key);
        let shown = format!("{keys:?}");
        assert!(!shown.contains(&key) && shown.contains(&keys.id), "{shown}");
        for shown in [format!("{entry:?}"), format!("{taken:?}")] {
            assert!(!shown.contains(&key), "{shown}");
            assert!(
                shown.contains(&keys.id) && shown.contains("media"),
                "{shown}"
            );
        }
    }

    #[test]
    fn expiry_one_use_and_list() {
        let clock = FakeClock(Cell::new(1000));
        let st = Store::new(tmp("expiry"), &clock);
        let m = st
            .make(Kind::Offer, "media", "-", 10, &mut Counter(1))
            .unwrap();
        let id = derive(&normalize(m.code.expose()).unwrap()).id;
        let l = st.list().unwrap();
        assert_eq!(
            (l.len(), l[0].expires_in, l[0].share.as_str()),
            (1, 600, "media")
        );
        // the file holds only derived values
        let text = std::fs::read_to_string(&st.path).unwrap();
        assert!(
            !text.contains(m.code.expose()) && !text.contains(&normalize(m.code.expose()).unwrap())
        );
        assert!(matches!(
            st.take(Kind::Offer, &id, "10.0.0.2").unwrap(),
            Taken::Found(_)
        ));
        assert!(matches!(
            st.take(Kind::Offer, &id, "10.0.0.2").unwrap(),
            Taken::Unknown { .. }
        ));
        let m = st
            .make(Kind::Offer, "media", "-", 1, &mut Counter(9))
            .unwrap();
        let id2 = derive(&normalize(m.code.expose()).unwrap()).id;
        clock.0.set(1000 + 61);
        assert!(matches!(
            st.take(Kind::Offer, &id2, "10.0.0.2").unwrap(),
            Taken::Unknown { .. }
        ));
        assert!(st.list().unwrap().is_empty());
    }

    #[test]
    fn kind_must_match_and_limits() {
        let clock = FakeClock(Cell::new(0));
        let st = Store::new(tmp("kind"), &clock);
        let mut rng = Counter(5);
        let m = st.make(Kind::Receive, "-", "-", 5, &mut rng).unwrap();
        let id = derive(&normalize(m.code.expose()).unwrap()).id;
        assert!(matches!(
            st.take(Kind::Offer, &id, "a").unwrap(),
            Taken::Unknown { .. }
        ));
        assert!(matches!(
            st.take(Kind::Receive, &id, "a").unwrap(),
            Taken::Found(_)
        ));
        for _ in 0..MAX_OPEN {
            st.make(Kind::Offer, "s", "-", 5, &mut rng).unwrap();
        }
        assert!(matches!(
            st.make(Kind::Offer, "s", "-", 5, &mut rng),
            Err(Error::Refused(_))
        ));
        assert!(matches!(
            st.make(Kind::Offer, "s", "-", 61, &mut rng),
            Err(Error::Refused(_))
        ));
        assert_eq!(st.cancel_all().unwrap(), MAX_OPEN);
    }

    #[test]
    fn rate_limit_per_source_then_window_passes() {
        let clock = FakeClock(Cell::new(0));
        let st = Store::new(tmp("rate"), &clock);
        for _ in 0..RATE_FAILS {
            assert_eq!(
                st.take(Kind::Offer, "x", "1.1.1.1").unwrap(),
                Taken::Unknown { burned: false }
            );
        }
        assert_eq!(
            st.take(Kind::Offer, "x", "1.1.1.1").unwrap(),
            Taken::RateLimited
        );
        // another source is not limited
        assert_eq!(
            st.take(Kind::Offer, "x", "2.2.2.2").unwrap(),
            Taken::Unknown { burned: false }
        );
        clock.0.set(RATE_WINDOW + 1);
        assert_eq!(
            st.take(Kind::Offer, "x", "1.1.1.1").unwrap(),
            Taken::Unknown { burned: false }
        );
    }

    #[test]
    fn twenty_failures_burn_every_code() {
        let clock = FakeClock(Cell::new(0));
        let st = Store::new(tmp("burn"), &clock);
        let mut rng = Counter(2);
        st.make(Kind::Offer, "s", "-", 10, &mut rng).unwrap();
        let mut burned = false;
        for i in 0..BURN_FAILS {
            clock.0.set((i as u64) * 20); // 20 s apart: no single source reaches 5 in a minute
            let src = format!("10.0.0.{i}");
            burned = matches!(
                st.take(Kind::Offer, "x", &src).unwrap(),
                Taken::Unknown { burned: true }
            );
        }
        assert!(burned);
        assert!(st.list().unwrap().is_empty());
    }

    fn offer_flow(name: &str, host: &FakeHost, bound: &str) -> (Reply, String, Vec<u8>) {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp(name), &clock);
        let m = st
            .make(Kind::Offer, "media", bound, 10, &mut Counter(4))
            .unwrap();
        let norm = normalize(m.code.expose()).unwrap();
        let req = claim_request(&norm, "beta", KEY).unwrap();
        let r = claim(&st, host, &mut Counter(8), req.as_bytes(), "10.0.0.5");
        (r, norm, req.into_bytes())
    }

    #[test]
    fn claim_end_to_end() {
        let host = FakeHost::new();
        let (r, norm, req) = offer_flow("f1", &host, "-");
        assert!(r.error.is_none());
        let inner = open_claim(&norm, &req, &r.body).unwrap();
        assert_eq!(inner["login"], "remote-beta");
        assert_eq!(inner["password"], "pw-secret-123");
        assert!(!r.body.to_string().contains("pw-secret"));
        assert_eq!(host.kinds(), vec!["remote.claimed"]);
        // a different request body does not open the box (the body is associated data)
        assert!(open_claim(&norm, b"{}", &r.body).is_none());
    }

    #[test]
    fn claim_refusals_have_one_shape() {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp("refuse"), &clock);
        let host = FakeHost::new();
        let bad = claim_request("ABCDEFGHJKLMNPQR", "beta", KEY).unwrap();
        let r = claim(&st, &host, &mut Counter(1), bad.as_bytes(), "10.0.0.5");
        assert_eq!(r.body, json!({"v": 1, "error": "code.unknown"}));
        let r = claim(&st, &host, &mut Counter(1), b"not json", "10.0.0.5");
        assert_eq!(r.body, json!({"v": 1, "error": "code.unknown"}));
        let taken = FakeHost {
            taken: true,
            ..FakeHost::new()
        };
        let (r, _, _) = offer_flow("f2", &taken, "-");
        assert_eq!(r.error, Some(Refusal::Unknown));
        assert_eq!(r.body, json!({"v": 1, "error": "code.unknown"}));
        let down = FakeHost {
            down: true,
            ..FakeHost::new()
        };
        let (r, _, _) = offer_flow("f3", &down, "-");
        assert_eq!(r.body, json!({"v": 1, "error": "code.unavailable"}));
    }

    #[test]
    fn claim_is_one_use_even_when_the_account_step_fails() {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp("once"), &clock);
        let m = st
            .make(Kind::Offer, "media", "-", 10, &mut Counter(4))
            .unwrap();
        let norm = normalize(m.code.expose()).unwrap();
        let req = claim_request(&norm, "beta", KEY).unwrap();
        let down = FakeHost {
            down: true,
            ..FakeHost::new()
        };
        assert_eq!(
            claim(&st, &down, &mut Counter(1), req.as_bytes(), "s").error,
            Some(Refusal::Unavailable)
        );
        let ok = FakeHost::new();
        assert_eq!(
            claim(&st, &ok, &mut Counter(1), req.as_bytes(), "s").error,
            Some(Refusal::Unknown)
        );
    }

    #[test]
    fn rate_limited_claim_answers_429_shape_and_events() {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp("rate429"), &clock);
        let host = FakeHost::new();
        let bad = claim_request("ABCDEFGHJKLMNPQR", "beta", KEY).unwrap();
        let mut last = None;
        for _ in 0..=RATE_FAILS {
            last = Some(claim(
                &st,
                &host,
                &mut Counter(1),
                bad.as_bytes(),
                "10.0.0.9",
            ));
        }
        assert_eq!(last.unwrap().error, Some(Refusal::Rate));
        assert!(host.kinds().iter().all(|k| k == "remote.claim.refused"));
    }

    #[test]
    fn push_end_to_end_and_wrong_code() {
        let clock = FakeClock(Cell::new(10));
        let st = Store::new(tmp("push"), &clock);
        let m = st
            .make(Kind::Receive, "-", "-", 10, &mut Counter(6))
            .unwrap();
        let norm = normalize(m.code.expose()).unwrap();
        let inner = Inner {
            server: "alpha".into(),
            host: "alpha.local".into(),
            share: "media".into(),
            login: "remote-beta".into(),
            domain: "HOME".into(),
            password: Secret::new("pw-secret-123"),
            hostkey: String::new(),
        };
        let body = push_body(&norm, &inner, &mut Counter(2)).unwrap();
        assert!(!body.contains("pw-secret"));
        let host = FakeHost::new();
        // a push sealed with another code is refused, and it uses up B's code only by id (unknown id: a failure)
        let other = push_body("ABCDEFGHJKLMNPQR", &inner, &mut Counter(2)).unwrap();
        assert_eq!(
            accept(&st, &host, other.as_bytes(), "10.0.0.7").error,
            Some(Refusal::Unknown)
        );
        let r = accept(&st, &host, body.as_bytes(), "10.0.0.7");
        assert!(r.error.is_none());
        assert_eq!(
            accept(&st, &host, body.as_bytes(), "10.0.0.7").error,
            Some(Refusal::Unknown)
        );
    }

    #[test]
    fn constant_time_compare() {
        assert!(ct_eq(b"abc", b"abc"));
        assert!(!ct_eq(b"abc", b"abd"));
        assert!(!ct_eq(b"abc", b"abcd"));
        assert!(ct_eq(b"", b""));
        assert!(!ct_eq(b"", b"a") && !ct_eq(b"a", b""));
    }

    // ------------------------------------------------------------ fixed bytes: both sides of a pairing must keep agreeing

    /// Gives the byte values in order, 0 to 255 and round again.
    struct EveryByte(u8);
    impl Random for EveryByte {
        fn fill(&mut self, buf: &mut [u8]) -> Result<()> {
            for b in buf.iter_mut() {
                *b = self.0;
                self.0 = self.0.wrapping_add(1);
            }
            Ok(())
        }
    }

    const FIXED_CODE: &str = "ABCDEFGHJKLMNPQR";
    const FIXED_ID: &str = "c361cfe86e4334a632f730f999a0e54a7ea292c89817aebfbd0bfecd94b34aba";

    #[test]
    fn every_random_byte_maps_to_a_fixed_letter() {
        assert_eq!(new_code(&mut Counter(1)).unwrap(), "GBGB-GBGB-GBGB-GBGB");
        let mut rng = EveryByte(0);
        for _ in 0..8 {
            assert_eq!(new_code(&mut rng).unwrap(), "ABCD-EFGH-JKLM-NPQR");
            assert_eq!(new_code(&mut rng).unwrap(), "STUV-WXYZ-2345-6789");
        }
    }

    #[test]
    fn derived_values_and_boxes_have_fixed_bytes() {
        let keys = derive(FIXED_CODE);
        assert_eq!(keys.id, FIXED_ID);
        assert_eq!(
            hex(&keys.key),
            "89268a6620ce1063d07cd77223673a44d31e7a45b3e1373e756d2438a9c3ccc6"
        );
        assert_eq!(
            hex(&seal(&keys, &[7u8; 12], b"aad", b"plain text").unwrap()),
            "48e291c70d1afb85782920621ea8e260660547305cd05b9dad48"
        );
        let answer = seal_answer(&keys, &mut Counter(3), b"request", b"{\"a\":1}").unwrap();
        assert_eq!(
            answer.to_string(),
            r#"{"v":1,"nonce":"ZCNEQyRjBIPko8TD","box":"w2+GPH2FhVCaMnmYkcY63f1lQtfnlZg="}"#
        );
    }

    #[test]
    fn request_push_and_fingerprint_have_fixed_text() {
        let inner = Inner {
            server: "alpha".into(),
            host: "alpha.local".into(),
            share: "media".into(),
            login: "remote-beta".into(),
            domain: "HOME".into(),
            password: Secret::new("pw-secret-123"),
            hostkey: String::new(),
        };
        let sealed = "8uxCtxEBpZVlNEEAS9Ms1QUYvGn3JxKy0LNxc0ojT0aWorIQFZyAJunqVfFOxTMgKxgPTMVB6+oJ1lKyD4TSi2c5tkebpb8eHiKmRHOT4YKPNWxDvpmUH8veV+9hLDBNTlxMZiFNgvFwXAxqDbQbIKV6K/cUzm6wJ4zdn+mozjZcOgIcduATbUsry17TuA6SWZFf2Dw=";
        assert_eq!(
            push_body(FIXED_CODE, &inner, &mut Counter(2)).unwrap(),
            format!(r#"{{"v":1,"nonce":"RWLlwoUiJYLF4mVC","box":"{sealed}","id":"{FIXED_ID}"}}"#)
        );
        assert_eq!(
            claim_request(FIXED_CODE, "beta", KEY).unwrap(),
            format!(r#"{{"v":1,"id":"{FIXED_ID}","name":"beta","hostkey":"{KEY}"}}"#)
        );
        assert_eq!(
            fingerprint(KEY).unwrap(),
            "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
        );
    }

    #[test]
    fn base64_has_fixed_text() {
        let data = [0xfbu8, 0xff, 0xbf, 0x00, 0x10, 0x83, 0xfe];
        let expected = [
            ("", ""),
            ("+w==", "+w"),
            ("+/8=", "+/8"),
            ("+/+/", "+/+/"),
            ("+/+/AA==", "+/+/AA"),
            ("+/+/ABA=", "+/+/ABA"),
            ("+/+/ABCD", "+/+/ABCD"),
            ("+/+/ABCD/g==", "+/+/ABCD/g"),
        ];
        for (length, (padded, bare)) in expected.into_iter().enumerate() {
            assert_eq!(b64(&data[..length]), padded);
            assert_eq!(b64_with(&data[..length], false), bare);
        }
        let every: Vec<u8> = (0..=255).collect();
        assert_eq!(unb64(&b64(&every)).unwrap(), every);
        assert_eq!(
            hex(&Sha256::digest(b64(&every).as_bytes())),
            "ab7727e21f4bbba6508dd72804d97435a78eb44a1e277af1c0f65a8522de382e"
        );
    }

    #[test]
    fn decoding_accepts_and_refuses_the_same_text() {
        let base64: [(&str, Option<&[u8]>); 16] = [
            ("", Some(b"")),
            ("=", Some(b"")),
            ("====", Some(b"")),
            ("Z", Some(b"")),
            ("Zg", Some(b"f")),
            ("Zg==", Some(b"f")),
            ("Zg=====", Some(b"f")),
            ("Zh==", Some(b"f")),
            ("Zm9", Some(b"fo")),
            ("Zm9vY", Some(b"foo")),
            ("+/+/", Some(&[251, 255, 191])),
            ("Zm=9v", None),
            ("Zm9v!", None),
            ("Zm 9v", None),
            ("-_", None),
            ("\u{e4}\u{e4}", None),
        ];
        for (text, bytes) in base64 {
            assert_eq!(unb64(text).as_deref(), bytes, "{text:?}");
        }
        // u8::from_str_radix takes a leading "+"
        let hexadecimal: [(&str, Option<&[u8]>); 14] = [
            ("", Some(b"")),
            ("00", Some(&[0])),
            ("0aFf", Some(&[10, 255])),
            ("+f", Some(&[15])),
            ("0", None),
            ("-1", None),
            ("f+", None),
            (" 1", None),
            ("zz", None),
            ("abc", None),
            ("0g", None),
            ("++", None),
            ("\u{e4}\u{e4}", None),
            ("a\u{e4}", None),
        ];
        for (text, bytes) in hexadecimal {
            assert_eq!(unhex(text).as_deref(), bytes, "{text:?}");
        }
    }

    #[test]
    fn names_are_checked() {
        assert!(valid_name("beta") && valid_name("a-1"));
        assert!(
            !valid_name("Beta")
                && !valid_name("-a")
                && !valid_name(&"a".repeat(21))
                && !valid_name("a_b")
        );
        assert!(valid_share("My.Share_1") && !valid_share("a/b"));
        assert!(valid_host("alpha.local:8480") && !valid_host("a b"));
    }
}
