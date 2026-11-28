//! The code store: open codes (derived values only) and failed claims, one file with a lock; the rate limit lives here.

use super::encoding::hex;
use super::{Clock, Random, derive, new_code, normalize};
use crate::{Error, Result, Secret};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

pub const MAX_OPEN: usize = 5;
pub const MAX_MINUTES: u64 = 60;
pub const DEFAULT_MINUTES: u64 = 10;
/// Failed claims per source and window before that source gets `code.rate`.
pub const RATE_FAILS: usize = 5;
pub const RATE_WINDOW: u64 = 60;
/// Failed claims of all sources in the burn window that end every open code.
pub const BURN_FAILS: usize = 20;
pub const BURN_WINDOW: u64 = 600;

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
    pub(super) path: PathBuf,
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
        let keys = derive(&norm)?;
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

/// Equal without stopping at the first difference.
pub(super) fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    // only the lowest byte of the length difference goes in
    let [mut d, ..] = (a.len() ^ b.len()).to_le_bytes();
    for (x, y) in a.iter().zip(b.iter()) {
        d |= x ^ y;
    }
    d == 0
}

pub fn default_store_path() -> PathBuf {
    std::env::var_os("HS_REMOTE_CODES")
        .filter(|v| !v.is_empty())
        .map_or_else(
            || Path::new("/run/hs/remote-codes.json").to_path_buf(),
            PathBuf::from,
        )
}
