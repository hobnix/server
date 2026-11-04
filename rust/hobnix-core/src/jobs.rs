//! Job store: one JSON record per job in a directory (docs/adr/0004-job-record.md, strangler step #137).
//!
//! The contract is scripts/job-record.py, byte for byte: the same file names, the same JSON layout, the same
//! messages. Where that program does something that looks accidental it is mirrored on purpose (marked "mirrored").
//! The two things that touch the machine, `systemctl is-active` and the boot time, sit behind [`System`] so tests use fakes.

use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Records beyond the newest KEEP_COUNT are removed when they are also older than KEEP_DAYS.
pub const KEEP_COUNT: usize = 200;
pub const KEEP_DAYS: f64 = 30.0;
/// The values of `--source`.
pub const SOURCES: [&str; 4] = ["cli", "web", "timer", "extension"];

/// `step` of a record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Step {
    pub n: i64,
    pub of: i64,
    pub text: String,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `progress` of a record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Progress {
    pub done: i64,
    pub total: i64,
    pub unit: String,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `error` of a record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorInfo {
    pub category: String,
    pub message: String,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// `cancel` of a record.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cancel {
    pub requested_by: Option<String>,
    pub at: String,
    pub safe: bool,
    /// Keys this code does not know (a newer writer or Python): kept, written after the known ones.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

/// One job record. The field order is the order in the file (ADR 0004 decision 3); every key is always written, absent = null.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub id: Option<String>,
    pub slug: Option<String>,
    pub description: Option<String>,
    pub source: Option<String>,
    pub initiator: Option<String>,
    pub unit: Option<String>,
    pub queued: Option<String>,
    pub started: Option<String>,
    pub ended: Option<String>,
    pub state: Option<String>,
    pub exit: Option<i64>,
    pub step: Option<Step>,
    pub progress: Option<Progress>,
    pub error: Option<ErrorInfo>,
    pub result: Option<serde_json::Value>,
    pub cancel: Option<Cancel>,
    pub version: Option<i64>,
}

impl Record {
    fn is_active(&self) -> bool {
        matches!(self.state.as_deref(), Some("queued" | "running"))
    }
}

/// What a reconcile run did: one line per record marked interrupted (id, slug, description) and the failures.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Reconciled {
    pub lines: Vec<(String, String, String)>,
    pub errors: Vec<String>,
}

/// The two questions that need the machine.
pub trait System {
    /// True when systemd says the unit is active or activating; any other answer (or no systemctl) means it is gone.
    fn unit_alive(&self, unit: &str) -> bool;
    /// Boot time as seconds since the epoch, or None when unknown.
    fn boot_time(&self) -> Option<f64>;
}

/// The real machine: `HS_SYSTEMCTL` (split like shlex) and `HS_UPTIME_FILE` (default /proc/uptime) as in job-record.py.
pub struct RealSystem;

impl System for RealSystem {
    fn unit_alive(&self, unit: &str) -> bool {
        if unit.is_empty() {
            return false;
        }
        let spec = env_nonempty("HS_SYSTEMCTL").unwrap_or_else(|| "systemctl".to_string());
        // mirrored: an unclosed quote is an uncaught error in Python (exit 1); here the unit counts as gone
        let Some(mut argv) = shlex_split(&spec) else {
            return false;
        };
        argv.push("is-active".to_string());
        argv.push(unit.to_string());
        let Ok(mut child) = Command::new(&argv[0])
            .args(&argv[1..])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        else {
            return false;
        };
        let start = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if start.elapsed() < Duration::from_secs(20) => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
            }
        }
        let mut out = Vec::new();
        if let Some(mut so) = child.stdout.take() {
            let _ = so.read_to_end(&mut out);
        }
        matches!(
            String::from_utf8_lossy(&out).trim(),
            "active" | "activating"
        )
    }

    fn boot_time(&self) -> Option<f64> {
        let path = env_nonempty("HS_UPTIME_FILE").unwrap_or_else(|| "/proc/uptime".to_string());
        let text = fs::read_to_string(path).ok()?;
        let up: f64 = text.split_whitespace().next()?.parse().ok()?;
        up.is_finite().then(|| now_f64() - up)
    }
}

fn env_nonempty(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

/// shlex.split (POSIX mode, no comments); None for an unclosed quote or a trailing backslash.
pub fn shlex_split(s: &str) -> Option<Vec<String>> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_token = false;
    let mut it = s.chars();
    while let Some(c) = it.next() {
        match c {
            ' ' | '\t' | '\r' | '\n' => {
                if in_token {
                    out.push(std::mem::take(&mut cur));
                    in_token = false;
                }
            }
            '\\' => {
                cur.push(it.next()?);
                in_token = true;
            }
            '\'' => {
                in_token = true;
                loop {
                    match it.next()? {
                        '\'' => break,
                        ch => cur.push(ch),
                    }
                }
            }
            '"' => {
                in_token = true;
                loop {
                    match it.next()? {
                        '"' => break,
                        '\\' => {
                            let n = it.next()?;
                            if n != '"' && n != '\\' {
                                cur.push('\\');
                            }
                            cur.push(n);
                        }
                        ch => cur.push(ch),
                    }
                }
            }
            ch => {
                cur.push(ch);
                in_token = true;
            }
        }
    }
    if in_token {
        out.push(cur);
    }
    Some(out)
}

// ---- time by hand (std only) ----

fn now_f64() -> f64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => -e.duration().as_secs_f64(),
    }
}

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = y - i64::from(m <= 2);
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = i64::from(if m > 2 { m - 3 } else { m + 9 });
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn split_secs(secs: i64) -> (i64, u32, u32, i64, i64, i64) {
    let (y, mo, d) = civil_from_days(secs.div_euclid(86_400));
    let rem = secs.rem_euclid(86_400);
    (y, mo, d, rem / 3600, rem % 3600 / 60, rem % 60)
}

/// `%Y-%m-%dT%H:%M:%SZ`.
pub fn format_iso(secs: i64) -> String {
    let (y, mo, d, h, mi, s) = split_secs(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// `%Y%m%d-%H%M%S`.
fn format_id_time(secs: i64) -> String {
    let (y, mo, d, h, mi, s) = split_secs(secs);
    format!("{y:04}{mo:02}{d:02}-{h:02}{mi:02}{s:02}")
}

fn days_in_month(y: i64, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        _ => 28,
    }
}

/// strptime("%Y-%m-%dT%H:%M:%SZ") as seconds since the epoch; like Python the numbers need not be zero padded.
pub fn parse_iso(s: &str) -> Option<i64> {
    fn num(s: &str, min: usize, max: usize) -> Option<(i64, &str)> {
        let n = s.bytes().take(max).take_while(u8::is_ascii_digit).count();
        if n < min {
            return None;
        }
        Some((s[..n].parse().ok()?, &s[n..]))
    }
    fn lit(s: &str, c: char) -> Option<&str> {
        s.strip_prefix(c)
    }
    let (y, r) = num(s, 4, 4)?;
    let (mo, r) = num(lit(r, '-')?, 1, 2)?;
    let (d, r) = num(lit(r, '-')?, 1, 2)?;
    let (h, r) = num(lit(r, 'T')?, 1, 2)?;
    let (mi, r) = num(lit(r, ':')?, 1, 2)?;
    let (se, r) = num(lit(r, ':')?, 1, 2)?;
    if !lit(r, 'Z')?.is_empty() {
        return None;
    }
    if y < 1 || !(1..=12).contains(&mo) || h > 23 || mi > 59 || se > 59 {
        return None;
    }
    let mo = mo as u32;
    if d < 1 || d > i64::from(days_in_month(y, mo)) {
        return None;
    }
    Some(days_from_civil(y, mo, d as u32) * 86_400 + h * 3600 + mi * 60 + se)
}

fn now_secs() -> i64 {
    now_f64().floor() as i64
}

fn now_iso() -> String {
    format_iso(now_secs())
}

/// Four random lower-case letters: /dev/urandom, else the clock.
fn random_suffix() -> String {
    let mut letters = String::new();
    let mut buf = [0u8; 32];
    if let Ok(mut f) = fs::File::open("/dev/urandom") {
        if f.read_exact(&mut buf).is_ok() {
            for b in buf {
                // 208 = 8 * 26: drop the bytes that would make some letters likelier
                if b < 208 && letters.len() < 4 {
                    letters.push(char::from(b'a' + b % 26));
                }
            }
        }
    }
    if letters.len() < 4 {
        let mut x = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(1)
            ^ (u64::from(std::process::id()) << 32)
            | 1;
        while letters.len() < 4 {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            letters.push(char::from(b'a' + (x % 26) as u8));
        }
    }
    letters
}

fn failed(msg: impl Into<String>) -> Error {
    Error::Failed(msg.into())
}

/// The OS text of an I/O error without Rust's " (os error N)" (what Python calls strerror).
fn strerror(e: &std::io::Error) -> String {
    let s = e.to_string();
    match s.rfind(" (os error ") {
        Some(i) => s[..i].to_string(),
        None => s,
    }
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

/// `[0-9]{8}-[0-9]{6}-[A-Za-z0-9-]+-[a-z]{4}` as a full match.
pub fn valid_id(id: &str) -> bool {
    let b = id.as_bytes();
    // 8 + 1 + 6 + 1 + (at least 1) + 1 + 4
    if b.len() < 22 || !id.is_ascii() {
        return false;
    }
    let digits = |s: &[u8]| s.iter().all(u8::is_ascii_digit);
    digits(&b[..8])
        && b[8] == b'-'
        && digits(&b[9..15])
        && b[15] == b'-'
        && b[16..b.len() - 5]
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || *c == b'-')
        && b[b.len() - 5] == b'-'
        && b[b.len() - 4..].iter().all(u8::is_ascii_lowercase)
}

fn one_line(s: Option<&str>) -> String {
    let mut out = String::new();
    let mut in_ws = false;
    for c in s.unwrap_or("").chars() {
        if matches!(c, '\t' | '\r' | '\n') {
            if !in_ws {
                out.push(' ');
                in_ws = true;
            }
        } else {
            out.push(c);
            in_ws = false;
        }
    }
    let t = out.trim();
    if t.is_empty() {
        "-".to_string()
    } else {
        t.to_string()
    }
}

fn list_json(dir: &Path) -> Option<Vec<String>> {
    let rd = fs::read_dir(dir).ok()?;
    Some(
        rd.filter_map(|e| e.ok()?.file_name().into_string().ok())
            .filter(|n| n.ends_with(".json"))
            .collect(),
    )
}

/// The directory of records and its rate limit.
pub struct Store {
    pub dir: PathBuf,
    /// Seconds between two step (or progress) writes of one job (`HS_JOB_RATE`, default 1).
    pub rate: f64,
}

impl Store {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Store {
            dir: dir.into(),
            rate: 1.0,
        }
    }

    fn path_of(&self, id: &str) -> Result<PathBuf> {
        if !valid_id(id) {
            return Err(failed("bad job id"));
        }
        Ok(self.dir.join(format!("{id}.json")))
    }

    fn stamp_path(&self, id: &str, kind: &str) -> PathBuf {
        self.dir.join(format!("{id}.{kind}.stamp"))
    }

    fn lock_path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.lock"))
    }

    fn ensure_dir(&self) -> Result<()> {
        let d = &self.dir;
        fs::create_dir_all(d)
            .and_then(|()| set_mode(d, 0o755))
            .map_err(|e| failed(format!("cannot create {}: {}", d.display(), strerror(&e))))
    }

    pub fn load(&self, id: &str) -> Result<Record> {
        let p = self.path_of(id)?;
        let bytes = fs::read(&p)
            .map_err(|e| failed(format!("cannot read record {id}: {}", strerror(&e))))?;
        let not_json = || failed(format!("record {id} is not valid JSON"));
        let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| not_json())?;
        if !value.is_object() {
            return Err(failed(format!("record {id} is not an object")));
        }
        // mirrored difference: a field of the wrong type is "not valid JSON" here; Python carries it along
        serde_json::from_value(value).map_err(|_| not_json())
    }

    /// Atomic write: temp file in the same directory, fsync, mode 0644, rename.
    fn save(&self, rec: &Record) -> Result<()> {
        // mirrored: the file name comes from the id inside the record, not from the id asked for
        let p = self.path_of(rec.id.as_deref().unwrap_or(""))?;
        let mut tmp = p.clone().into_os_string();
        tmp.push(format!(".{}.tmp", std::process::id()));
        let tmp = PathBuf::from(tmp);
        let write = || -> std::io::Result<()> {
            let mut text = serde_json::to_string_pretty(rec).map_err(std::io::Error::other)?;
            text.push('\n');
            let mut f = fs::File::create(&tmp)?;
            f.write_all(text.as_bytes())?;
            f.flush()?;
            f.sync_all()?;
            drop(f);
            set_mode(&tmp, 0o644)?;
            fs::rename(&tmp, &p)
        };
        write().map_err(|e| {
            let _ = fs::remove_file(&tmp);
            failed(format!("cannot write record: {}", strerror(&e)))
        })
    }

    /// Read-modify-write of one record under an exclusive lock `<id>.lock`.
    /// mirrored: the lock file is made from the id as given, before it is checked.
    fn locked<T>(&self, id: &str, f: impl FnOnce() -> Result<T>) -> Result<T> {
        let mut oo = fs::OpenOptions::new();
        oo.create(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            oo.mode(0o644);
        }
        let file = oo
            .open(self.lock_path(id))
            .map_err(|e| failed(format!("cannot lock record: {}", strerror(&e))))?;
        file.lock()
            .map_err(|e| failed(format!("cannot lock record: {}", strerror(&e))))?;
        f()
    }

    /// True when the last write of this kind was less than `rate` seconds ago (mtime of the stamp file).
    fn rate_limited(&self, id: &str, kind: &str) -> bool {
        match fs::metadata(self.stamp_path(id, kind)).and_then(|m| m.modified()) {
            Ok(t) => {
                let age = match SystemTime::now().duration_since(t) {
                    Ok(d) => d.as_secs_f64(),
                    Err(e) => -e.duration().as_secs_f64(),
                };
                age < self.rate
            }
            Err(_) => false,
        }
    }

    fn touch_stamp(&self, id: &str, kind: &str) {
        let _ = fs::File::create(self.stamp_path(id, kind));
    }

    fn cleanup(&self, id: &str, stamps: bool) {
        if stamps {
            for kind in ["step", "progress"] {
                let _ = fs::remove_file(self.stamp_path(id, kind));
            }
        }
        let _ = fs::remove_file(self.lock_path(id));
    }

    /// Remove records beyond the newest KEEP_COUNT that are also older than KEEP_DAYS, with their `<id>.*` files.
    fn retention(&self) {
        let Some(names) = list_json(&self.dir) else {
            return;
        };
        let mut items: Vec<(f64, String)> = names
            .into_iter()
            .filter_map(|n| {
                let t = fs::metadata(self.dir.join(&n)).ok()?.modified().ok()?;
                let m = match t.duration_since(UNIX_EPOCH) {
                    Ok(d) => d.as_secs_f64(),
                    Err(e) => -e.duration().as_secs_f64(),
                };
                Some((m, n))
            })
            .collect();
        items.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
        let limit = now_f64() - KEEP_DAYS * 86_400.0;
        for (mtime, n) in items.into_iter().skip(KEEP_COUNT) {
            if mtime < limit {
                let base = format!("{}.", &n[..n.len() - 5]);
                let mut victims = vec![n.clone()];
                if let Ok(rd) = fs::read_dir(&self.dir) {
                    victims.extend(
                        rd.filter_map(|e| e.ok()?.file_name().into_string().ok())
                            .filter(|x| x.starts_with(&base) && *x != n),
                    );
                }
                for v in victims {
                    let _ = fs::remove_file(self.dir.join(v));
                }
            }
        }
    }

    /// `new`: write a queued record, return its id.
    pub fn new_record(
        &self,
        slug: &str,
        desc: &str,
        unit: &str,
        source: &str,
        initiator: &str,
    ) -> Result<String> {
        if !SOURCES.contains(&source) {
            return Err(failed(format!("bad source: {source}")));
        }
        self.ensure_dir()?;
        let ts = now_secs();
        let mut clean = String::new();
        let mut in_run = false;
        for c in slug.chars() {
            if c.is_ascii_alphanumeric() {
                clean.push(c);
                in_run = false;
            } else if !in_run {
                clean.push('-');
                in_run = true;
            }
        }
        let mut clean = clean.trim_matches('-').to_string();
        if clean.is_empty() {
            clean = "job".to_string();
        }
        let id = format!("{}-{}-{}", format_id_time(ts), clean, random_suffix());
        let some = |s: &str| (!s.is_empty()).then(|| s.to_string());
        let rec = Record {
            id: Some(id.clone()),
            slug: Some(clean),
            description: Some(desc.to_string()),
            source: Some(source.to_string()),
            initiator: some(initiator),
            unit: some(unit),
            queued: Some(format_iso(ts)),
            state: Some("queued".to_string()),
            version: Some(1),
            ..Record::default()
        };
        self.save(&rec)?;
        self.retention();
        Ok(id)
    }

    pub fn run(&self, id: &str) -> Result<()> {
        self.locked(id, || {
            let mut rec = self.load(id)?;
            rec.state = Some("running".to_string());
            rec.started = Some(now_iso());
            self.save(&rec)
        })
    }

    pub fn step(&self, id: &str, n: i64, of: i64, text: &str) -> Result<()> {
        if self.rate_limited(id, "step") && n != of {
            return Ok(());
        }
        self.locked(id, || {
            let mut rec = self.load(id)?;
            rec.step = Some(Step {
                n,
                of,
                text: text.to_string(),
                ..Default::default()
            });
            self.save(&rec)
        })?;
        self.touch_stamp(id, "step");
        Ok(())
    }

    pub fn progress(&self, id: &str, done: i64, total: i64, unit: &str) -> Result<()> {
        if self.rate_limited(id, "progress") && done != total {
            return Ok(());
        }
        self.locked(id, || {
            let mut rec = self.load(id)?;
            rec.progress = Some(Progress {
                done,
                total,
                unit: unit.to_string(),
                ..Default::default()
            });
            self.save(&rec)
        })?;
        self.touch_stamp(id, "progress");
        Ok(())
    }

    /// `finish`: a cancelled record stays cancelled (the exit is stored, `ended` and `cancel` stay).
    pub fn finish(&self, id: &str, exit: i64) -> Result<()> {
        self.locked(id, || {
            let mut rec = self.load(id)?;
            rec.exit = Some(exit);
            if rec.state.as_deref() == Some("cancelled") {
                if rec.ended.as_deref().is_none_or(str::is_empty) {
                    rec.ended = Some(now_iso());
                }
            } else if exit == 0 {
                rec.ended = Some(now_iso());
                rec.state = Some("ok".to_string());
                rec.error = None;
            } else {
                rec.ended = Some(now_iso());
                rec.state = Some("failed".to_string());
                rec.error = Some(ErrorInfo {
                    category: "exit".to_string(),
                    message: format!("exit status {exit}"),
                    ..Default::default()
                });
            }
            self.save(&rec)
        })?;
        self.cleanup(id, true);
        Ok(())
    }

    /// `find-unit`: the id of the newest queued/running record of a unit (with or without `.service`).
    pub fn find_unit(&self, unit: &str) -> Result<String> {
        let mut names: Vec<String> = list_json(&self.dir)
            .unwrap_or_default()
            .into_iter()
            .map(|n| n[..n.len() - 5].to_string())
            .collect();
        names.sort_by(|a, b| b.cmp(a));
        let bare = unit.strip_suffix(".service").unwrap_or(unit);
        for id in names {
            let Ok(rec) = self.load(&id) else {
                continue;
            };
            let u = rec.unit.as_deref();
            if (u == Some(unit) || u == Some(bare)) && rec.is_active() {
                return Ok(id);
            }
        }
        Err(failed(format!("no running job record for {unit}")))
    }

    pub fn cancel(&self, id: &str, by: &str, safe: bool) -> Result<()> {
        self.locked(id, || {
            let mut rec = self.load(id)?;
            if !rec.is_active() {
                return Err(failed("job already finished"));
            }
            let at = now_iso();
            rec.state = Some("cancelled".to_string());
            rec.ended = Some(at.clone());
            rec.error = None;
            rec.cancel = Some(Cancel {
                requested_by: (!by.is_empty()).then(|| by.to_string()),
                at,
                safe,
                ..Default::default()
            });
            self.save(&rec)
        })
    }

    /// `uncancel`: the stop of the unit failed after the record was marked cancelled; the job still runs, so the record says so again.
    pub fn uncancel(&self, id: &str) -> Result<()> {
        self.locked(id, || {
            let mut rec = self.load(id)?;
            if rec.state.as_deref() != Some("cancelled") || rec.exit.is_some() {
                return Err(failed("job is not cancelled, or it ended already"));
            }
            rec.state = Some(
                if rec.started.is_some() {
                    "running"
                } else {
                    "queued"
                }
                .to_string(),
            );
            rec.ended = None;
            rec.cancel = None;
            self.save(&rec)
        })
    }

    /// `cancelled`: true when the record says cancelled.
    pub fn is_cancelled(&self, id: &str) -> Result<bool> {
        Ok(self.load(id)?.state.as_deref() == Some("cancelled"))
    }

    /// `get`: the file as it is (after it was checked to be a record).
    pub fn get(&self, id: &str) -> Result<Vec<u8>> {
        self.load(id)?;
        fs::read(self.path_of(id)?)
            .map_err(|e| failed(format!("cannot read record {id}: {}", strerror(&e))))
    }

    /// `reconcile`: mark queued/running records whose unit is gone as interrupted. Never re-runs anything.
    pub fn reconcile(&self, sys: &dyn System) -> Reconciled {
        let mut out = Reconciled::default();
        let Some(mut names) = list_json(&self.dir) else {
            return out;
        };
        names.sort();
        let boot = sys.boot_time();
        for n in names {
            let id = &n[..n.len() - 5];
            match self.reconcile_one(id, boot, sys) {
                Ok(Some(line)) => out.lines.push(line),
                Ok(None) => {}
                Err(e) => out.errors.push(e.to_string()),
            }
        }
        out
    }

    fn reconcile_one(
        &self,
        id: &str,
        boot: Option<f64>,
        sys: &dyn System,
    ) -> Result<Option<(String, String, String)>> {
        // no lock yet, so a finished record leaves no lock file behind
        if !self.load(id)?.is_active() {
            return Ok(None);
        }
        let marked = self.locked(id, || {
            let mut rec = self.load(id)?;
            if !rec.is_active() {
                return Ok(None);
            }
            let pick = match rec.started.as_deref() {
                Some(s) if !s.is_empty() => Some(s),
                _ => rec.queued.as_deref(),
            };
            let began = pick.and_then(parse_iso);
            if let (Some(b), Some(began)) = (boot, began) {
                if began as f64 >= b {
                    // started after this boot (a job may be between its record and its unit): not a restart victim
                    return Ok(None);
                }
            }
            if sys.unit_alive(rec.unit.as_deref().unwrap_or("")) {
                return Ok(None);
            }
            rec.ended = Some(match (boot, began) {
                (Some(b), Some(_)) => format_iso(b.floor() as i64),
                _ => now_iso(),
            });
            rec.state = Some("interrupted".to_string());
            rec.exit = None;
            rec.error = Some(ErrorInfo {
                category: "interrupted".to_string(),
                message: "the job did not finish; the server restarted or the unit stopped"
                    .to_string(),
                ..Default::default()
            });
            self.save(&rec)?;
            Ok(Some(rec))
        })?;
        let Some(rec) = marked else {
            return Ok(None);
        };
        self.cleanup(id, true);
        Ok(Some((
            id.to_string(),
            one_line(rec.slug.as_deref()),
            one_line(rec.description.as_deref()),
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    struct Tmp(PathBuf);
    impl Tmp {
        fn new() -> Tmp {
            let n = COUNTER.fetch_add(1, Ordering::SeqCst);
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let p = std::env::temp_dir().join(format!(
                "hobnix-jobs-test-{}-{n}-{nanos}",
                std::process::id()
            ));
            Tmp(p)
        }
        fn store(&self) -> Store {
            Store::new(&self.0)
        }
    }
    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    struct Fake {
        alive: Vec<&'static str>,
        boot: Option<f64>,
    }
    impl System for Fake {
        fn unit_alive(&self, unit: &str) -> bool {
            self.alive.contains(&unit)
        }
        fn boot_time(&self) -> Option<f64> {
            self.boot
        }
    }

    fn mk(store: &Store, unit: &str) -> String {
        store
            .new_record("pool sync", "hs pool sync", unit, "cli", "alice")
            .unwrap()
    }

    fn read(store: &Store, id: &str) -> String {
        fs::read_to_string(store.dir.join(format!("{id}.json"))).unwrap()
    }

    #[test]
    fn civil_dates() {
        assert_eq!(format_iso(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_iso(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(format_iso(1_709_210_096), "2024-02-29T12:34:56Z");
        assert_eq!(format_id_time(1_709_210_096), "20240229-123456");
        for s in [0, 86_399, 951_782_400, 1_709_210_096, 4_102_444_799] {
            assert_eq!(parse_iso(&format_iso(s)), Some(s));
        }
    }

    #[test]
    fn parse_iso_is_strict_about_shape() {
        assert_eq!(parse_iso("2024-1-5T1:2:3Z"), Some(1_704_416_523));
        for bad in [
            "",
            "2024-02-30T00:00:00Z",
            "2024-13-01T00:00:00Z",
            "2024-01-01T24:00:00Z",
            "2024-01-01T00:00:60Z",
            "2024-01-01 00:00:00Z",
            "2024-01-01T00:00:00",
            "2024-01-01T00:00:00Zx",
            "0000-01-01T00:00:00Z",
        ] {
            assert_eq!(parse_iso(bad), None, "{bad}");
        }
    }

    #[test]
    fn ids() {
        assert!(valid_id("20240101-120000-pool-sync-abcd"));
        assert!(valid_id("20240101-120000-a-abcd"));
        for bad in [
            "",
            "20240101-120000--abcd",
            "20240101-120000-a-abcD",
            "20240101-120000-a-abc",
            "2024010-120000-a-abcd",
            "20240101-120000-a_b-abcd",
            "../20240101-120000-a-abcd",
        ] {
            assert!(!valid_id(bad), "{bad}");
        }
    }

    #[test]
    fn shlex() {
        assert_eq!(
            shlex_split("sudo  -n 'a b' \"c\\\"d\" e\\ f"),
            Some(vec![
                "sudo".into(),
                "-n".into(),
                "a b".into(),
                "c\"d".into(),
                "e f".into()
            ])
        );
        assert_eq!(shlex_split("a ''"), Some(vec!["a".into(), String::new()]));
        assert_eq!(shlex_split("'open"), None);
        assert_eq!(shlex_split("end\\"), None);
        assert_eq!(shlex_split("  "), Some(vec![]));
    }

    #[test]
    fn new_writes_the_documented_record() {
        let t = Tmp::new();
        let s = t.store();
        let id = s
            .new_record("-- Pool/Sync!! --", "Café sync", "hs-job-x-1", "web", "")
            .unwrap();
        assert!(valid_id(&id), "{id}");
        assert!(id.contains("-Pool-Sync-"));
        let text = read(&s, &id);
        let keys: Vec<&str> = [
            "id",
            "slug",
            "description",
            "source",
            "initiator",
            "unit",
            "queued",
            "started",
            "ended",
            "state",
            "exit",
            "step",
            "progress",
            "error",
            "result",
            "cancel",
            "version",
        ]
        .to_vec();
        let mut at = 0;
        for k in keys {
            let pos = text[at..].find(&format!("\n  \"{k}\": ")).unwrap();
            at += pos + 1;
        }
        assert!(text.contains("\"description\": \"Café sync\""));
        assert!(text.contains("\"initiator\": null"));
        assert!(text.contains("\"state\": \"queued\""));
        assert!(text.contains("\"version\": 1\n}\n"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&s.dir), 0o755);
            assert_eq!(mode(&s.dir.join(format!("{id}.json"))), 0o644);
        }
        assert_eq!(
            s.new_record("x", "d", "", "bogus", "")
                .unwrap_err()
                .to_string(),
            "bad source: bogus"
        );
        assert!(s
            .new_record("!!!", "d", "", "cli", "")
            .unwrap()
            .contains("-job-"));
    }

    #[test]
    fn run_step_progress_finish() {
        let t = Tmp::new();
        let mut s = t.store();
        s.rate = 60.0;
        let id = mk(&s, "hs-job-pool-sync-1");
        s.run(&id).unwrap();
        s.step(&id, 1, 3, "first").unwrap();
        s.step(&id, 2, 3, "dropped by the rate limit").unwrap();
        s.step(&id, 3, 3, "last always counts").unwrap();
        s.progress(&id, 5, 10, "files").unwrap();
        s.progress(&id, 6, 10, "files").unwrap();
        let rec = s.load(&id).unwrap();
        assert_eq!(rec.state.as_deref(), Some("running"));
        assert_eq!(rec.step.unwrap().text, "last always counts");
        assert_eq!(rec.progress.unwrap().done, 5);
        assert!(s.stamp_path(&id, "step").exists());
        s.finish(&id, 3).unwrap();
        let rec = s.load(&id).unwrap();
        assert_eq!(rec.state.as_deref(), Some("failed"));
        assert_eq!(rec.exit, Some(3));
        assert_eq!(rec.error.unwrap().message, "exit status 3");
        assert!(!s.stamp_path(&id, "step").exists());
        assert!(!s.lock_path(&id).exists());
        s.finish(&id, 0).unwrap();
        let rec = s.load(&id).unwrap();
        assert_eq!(rec.state.as_deref(), Some("ok"));
        assert!(rec.error.is_none());
    }

    #[test]
    fn uncancel_puts_the_record_back() {
        let t = Tmp::new();
        let s = t.store();
        let id = mk(&s, "hs-job-un-0320");
        s.run(&id).unwrap();
        s.cancel(&id, "bob", true).unwrap();
        s.uncancel(&id).unwrap();
        let rec = s.load(&id).unwrap();
        assert_eq!(rec.state.as_deref(), Some("running"));
        assert!(rec.ended.is_none() && rec.cancel.is_none());
        assert!(s.uncancel(&id).is_err());
    }

    #[test]
    fn cancel_finish_and_find_unit() {
        let t = Tmp::new();
        let s = t.store();
        let id = mk(&s, "hs-job-gc-0320");
        assert_eq!(s.find_unit("hs-job-gc-0320.service").unwrap(), id);
        assert_eq!(s.find_unit("hs-job-gc-0320").unwrap(), id);
        assert_eq!(
            s.find_unit("other").unwrap_err().to_string(),
            "no running job record for other"
        );
        assert!(!s.is_cancelled(&id).unwrap());
        s.cancel(&id, "bob", true).unwrap();
        assert!(s.is_cancelled(&id).unwrap());
        let ended = s.load(&id).unwrap().ended;
        assert!(ended.is_some());
        s.finish(&id, 143).unwrap();
        let rec = s.load(&id).unwrap();
        assert_eq!(rec.state.as_deref(), Some("cancelled"));
        assert_eq!(rec.exit, Some(143));
        assert_eq!(rec.ended, ended);
        let c = rec.cancel.unwrap();
        assert_eq!(c.requested_by.as_deref(), Some("bob"));
        assert!(c.safe);
        assert_eq!(
            s.cancel(&id, "bob", true).unwrap_err().to_string(),
            "job already finished"
        );
        assert!(s.find_unit("hs-job-gc-0320").is_err());
    }

    #[test]
    fn find_unit_picks_the_highest_id() {
        let t = Tmp::new();
        let s = t.store();
        let a = mk(&s, "hs-job-x-1");
        let mut b = a.clone();
        b.replace_range(..8, "29990101");
        let mut rec = s.load(&a).unwrap();
        rec.id = Some(b.clone());
        s.save(&rec).unwrap();
        assert_eq!(s.find_unit("hs-job-x-1.service").unwrap(), b);
    }

    #[test]
    fn errors_are_one_line_messages() {
        let t = Tmp::new();
        let s = t.store();
        assert_eq!(s.load("nope").unwrap_err().to_string(), "bad job id");
        let id = "20240101-120000-gone-abcd";
        assert!(s
            .run(id)
            .unwrap_err()
            .to_string()
            .starts_with("cannot lock record: "));
        fs::create_dir_all(&s.dir).unwrap();
        #[cfg(unix)]
        assert_eq!(
            s.load(id).unwrap_err().to_string(),
            format!("cannot read record {id}: No such file or directory")
        );
        fs::write(s.dir.join(format!("{id}.json")), "{oops").unwrap();
        assert_eq!(
            s.load(id).unwrap_err().to_string(),
            format!("record {id} is not valid JSON")
        );
        fs::write(s.dir.join(format!("{id}.json")), "[1]").unwrap();
        assert_eq!(
            s.load(id).unwrap_err().to_string(),
            format!("record {id} is not an object")
        );
        assert!(s.get(id).is_err());
    }

    #[test]
    fn get_returns_the_file() {
        let t = Tmp::new();
        let s = t.store();
        let id = mk(&s, "u");
        assert_eq!(
            String::from_utf8(s.get(&id).unwrap()).unwrap(),
            read(&s, &id)
        );
    }

    #[test]
    fn retention_keeps_new_and_young() {
        let t = Tmp::new();
        let s = t.store();
        fs::create_dir_all(&s.dir).unwrap();
        let old = SystemTime::now() - Duration::from_secs(40 * 86_400);
        let make = |name: &str, when: SystemTime| {
            let f = fs::File::create(s.dir.join(name)).unwrap();
            f.set_modified(when).unwrap();
        };
        for i in 0..KEEP_COUNT {
            make(
                &format!("20240101-000000-keep{i:03}-abcd.json"),
                SystemTime::now(),
            );
        }
        make("20230101-000000-old-abcd.json", old);
        make("20230101-000000-old-abcd.step.stamp", old);
        make("20230101-000000-older-abcd.json", old);
        // an old record inside the newest KEEP_COUNT stays: all 200 fresh ones are newer, so the old ones go
        s.retention();
        assert!(!s.dir.join("20230101-000000-old-abcd.json").exists());
        assert!(!s.dir.join("20230101-000000-old-abcd.step.stamp").exists());
        assert!(!s.dir.join("20230101-000000-older-abcd.json").exists());
        assert!(s.dir.join("20240101-000000-keep000-abcd.json").exists());
        // fresh records beyond the count stay while they are young
        make("20240101-000000-extra-abcd.json", SystemTime::now());
        s.retention();
        assert!(s.dir.join("20240101-000000-extra-abcd.json").exists());
    }

    #[test]
    fn reconcile_marks_only_the_gone_ones() {
        let t = Tmp::new();
        let s = t.store();
        let gone = mk(&s, "hs-job-gone");
        let alive = mk(&s, "hs-job-alive");
        let done = mk(&s, "hs-job-done");
        let fresh = mk(&s, "hs-job-fresh");
        s.finish(&done, 0).unwrap();
        for id in [&gone, &alive] {
            let mut r = s.load(id).unwrap();
            r.started = Some("2024-01-01T00:00:00Z".into());
            r.description = Some("line\none\ttwo".into());
            s.save(&r).unwrap();
        }
        let boot = parse_iso("2024-06-01T00:00:30Z").unwrap() as f64;
        let sys = Fake {
            alive: vec!["hs-job-alive"],
            boot: Some(boot),
        };
        // `fresh` was queued now, after the fake boot
        let r = s.reconcile(&sys);
        assert!(r.errors.is_empty());
        assert_eq!(r.lines.len(), 1, "{:?}", r.lines);
        let line = r.lines.iter().find(|l| l.0 == gone).unwrap();
        assert_eq!(line.1, "pool-sync");
        assert_eq!(line.2, "line one two");
        let rec = s.load(&gone).unwrap();
        assert_eq!(rec.state.as_deref(), Some("interrupted"));
        assert_eq!(rec.ended.as_deref(), Some("2024-06-01T00:00:30Z"));
        assert_eq!(rec.exit, None);
        assert_eq!(rec.error.unwrap().category, "interrupted");
        assert!(!s.lock_path(&gone).exists());
        // the alive one and the one queued after boot stay as they are
        assert_eq!(s.load(&alive).unwrap().state.as_deref(), Some("queued"));
        assert_eq!(s.load(&fresh).unwrap().state.as_deref(), Some("queued"));
        assert_eq!(s.load(&done).unwrap().state.as_deref(), Some("ok"));
    }

    #[test]
    fn reconcile_spares_jobs_that_began_after_boot_and_reports_bad_records() {
        let t = Tmp::new();
        let s = t.store();
        let id = mk(&s, "hs-job-new");
        let sys = Fake {
            alive: vec![],
            boot: Some(now_f64() - 100.0),
        };
        fs::write(s.dir.join("garbage.json"), "{}").unwrap();
        let r = s.reconcile(&sys);
        assert!(r.lines.is_empty());
        assert_eq!(r.errors, vec!["bad job id".to_string()]);
        assert_eq!(s.load(&id).unwrap().state.as_deref(), Some("queued"));
        // without a boot time the unit decides
        let sys = Fake {
            alive: vec![],
            boot: None,
        };
        assert_eq!(s.reconcile(&sys).lines.len(), 1);
        assert_eq!(s.load(&id).unwrap().state.as_deref(), Some("interrupted"));
    }

    #[test]
    fn reconcile_without_a_directory_is_empty() {
        let t = Tmp::new();
        let r = t.store().reconcile(&Fake {
            alive: vec![],
            boot: None,
        });
        assert_eq!(r, Reconciled::default());
    }

    #[test]
    fn unknown_nested_keys_survive_a_round_trip() {
        let json = r#"{"id":"x","error":{"category":"exit","message":"m","hint":"keep me"},"cancel":{"requested_by":null,"at":"t","safe":true,"why":1},"result":{"b":2,"a":[1,2]}}"#;
        let rec: Record = serde_json::from_str(json).unwrap();
        let out = serde_json::to_string(&rec).unwrap();
        assert!(out.contains(r#""hint":"keep me""#));
        assert!(out.contains(r#""why":1"#));
        assert!(out.contains(r#""a":[1,2]"#));
    }

    #[test]
    fn one_line_collapses() {
        assert_eq!(one_line(None), "-");
        assert_eq!(one_line(Some(" \n\t ")), "-");
        assert_eq!(one_line(Some("a\r\n\tb ")), "a b");
    }
}
