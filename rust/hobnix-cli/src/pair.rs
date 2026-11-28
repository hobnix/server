//! Pairing of remote shares by code: `hobnix remote-codes|remote-claim|remote-accept` (the rows of `hs sys remote ...`) and the internal
//! `hobnix pair ...` that remote.sh calls. A code or a password is read from stdin and written to stdout only, never taken from an argument.

use hobnix_core::pair::{self, Clock, DEFAULT_MINUTES, Inner, Kind, OsRandom, Store, SystemClock};
use hobnix_core::pair_host::SystemHost;
use hobnix_core::{EXIT_OK, EXIT_REFUSED, Error, Result};
use serde_json::Value;
use std::fmt::Write as _;
use std::io::{Read, Write};

const LIMIT: u64 = 16 * 1024;

fn stdin_bytes() -> Result<Vec<u8>> {
    let mut b = Vec::new();
    std::io::stdin()
        .lock()
        .take(LIMIT + 1)
        .read_to_end(&mut b)
        .map_err(|_| Error::Failed("cannot read standard input".into()))?;
    if b.len() as u64 > LIMIT {
        return Err(Error::Refused("the input is too long".into()));
    }
    Ok(b)
}

/// Standard input as `key<TAB>value` lines (a code or a password never travels in an argument).
fn stdin_fields() -> Result<Value> {
    let text = String::from_utf8(stdin_bytes()?)
        .map_err(|_| Error::Refused("standard input is not text".into()))?;
    let mut m = serde_json::Map::new();
    for line in text.lines().filter(|l| !l.is_empty()) {
        let (k, v) = line
            .split_once('\t')
            .ok_or_else(|| Error::Refused("need key<TAB>value lines on standard input".into()))?;
        m.insert(k.to_string(), Value::String(v.to_string()));
    }
    Ok(Value::Object(m))
}

fn write_out(text: &str) -> Result<()> {
    let mut o = std::io::stdout().lock();
    o.write_all(text.as_bytes())
        .and_then(|()| o.flush())
        .map_err(|_| Error::Failed("cannot write the answer".into()))
}

fn source(args: &[String]) -> Result<String> {
    match args {
        [] => Ok("-".into()),
        [f, v] if f == "--source" && !v.is_empty() && v.len() <= 64 => Ok(v.clone()),
        _ => Err(Error::Refused("usage: --source <address>".into())),
    }
}

fn store(clock: &dyn Clock) -> Store<'_> {
    Store::new(pair::default_store_path(), clock)
}

/// `hs sys remote codes`: `share  server  expires_in`, one line per open code, `-` for an empty field.
pub(crate) fn codes(args: &[String]) -> Result<u8> {
    if !args.is_empty() {
        return Err(Error::Refused(
            "hs sys remote codes takes no arguments".into(),
        ));
    }
    let clock = SystemClock;
    let mut o = String::new();
    for c in store(&clock).list()? {
        let _ = writeln!(o, "{}\t{}\t{}", c.share, c.server, c.expires_in);
    }
    write_out(&o)?;
    Ok(EXIT_OK)
}

fn door(args: &[String], accept: bool) -> Result<u8> {
    let src = source(args)?;
    let body = stdin_bytes()?;
    let clock = SystemClock;
    let st = store(&clock);
    let host = SystemHost::from_env()?;
    let reply = if accept {
        pair::accept(&st, &host, &body, &src)
    } else {
        pair::claim(&st, &host, &mut OsRandom, &body, &src)
    };
    write_out(&format!("{}\n", reply.body))?;
    Ok(if reply.error.is_none() {
        EXIT_OK
    } else {
        EXIT_REFUSED
    })
}

/// `hs sys remote claim [--source <ip>]`: the request on stdin, the answer body on stdout; exit 1 and the refusal body for a refusal.
pub(crate) fn claim(args: &[String]) -> Result<u8> {
    door(args, false)
}

/// `hs sys remote accept [--source <ip>]`: the push on stdin (the reverse direction).
pub(crate) fn accept(args: &[String]) -> Result<u8> {
    door(args, true)
}

fn not_a_code() -> Error {
    Error::Refused("that is not a code (16 letters and digits)".into())
}

fn norm_from(v: &Value) -> Result<String> {
    v.get("code")
        .and_then(Value::as_str)
        .and_then(pair::normalize)
        .ok_or_else(not_a_code)
}

fn text<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}

/// `hobnix pair <word>`: make | cancel | check | request | open | push (internal, called by remote.sh).
pub(crate) fn run(args: &[String]) -> Result<u8> {
    match args.first().map(String::as_str) {
        Some("make") => make(args.get(1..).unwrap_or_default()),
        Some("cancel") => cancel(),
        Some("check") => check(),
        Some("request") => request(),
        Some("open") => open(),
        Some("push") => push(),
        _ => Err(Error::Refused(
            "usage: hobnix pair make|cancel|check|request|open|push".into(),
        )),
    }?;
    Ok(EXIT_OK)
}

/// `pair make <offer|receive> <share|-> <server|-> <minutes|->`: a new code and how long it is good for.
fn make(words: &[String]) -> Result<()> {
    let [kind, share, server, minutes] = words else {
        return Err(Error::Refused(
            "usage: pair make <offer|receive> <share|-> <server|-> <minutes>".into(),
        ));
    };
    let kind = match kind.as_str() {
        "offer" => Kind::Offer,
        "receive" => Kind::Receive,
        _ => return Err(Error::Refused("the kind is offer or receive".into())),
    };
    let minutes = if minutes == "-" {
        DEFAULT_MINUTES
    } else {
        minutes
            .parse()
            .map_err(|_| Error::Refused("minutes is a number".into()))?
    };
    let clock = SystemClock;
    let made = store(&clock).make(kind, share, server, minutes, &mut OsRandom)?;
    write_out(&format!(
        "code\t{}\nexpires_in\t{}\n",
        made.code.expose(),
        made.expires_in
    ))
}

fn cancel() -> Result<()> {
    let clock = SystemClock;
    let count = store(&clock).cancel_all()?;
    write_out(&format!("cancelled\t{count}\n"))
}

/// stdin: one line, the code as typed (maybe with @host); prints the code in groups, then the part after @ (or -).
fn check() -> Result<()> {
    let line = String::from_utf8_lossy(&stdin_bytes()?).trim().to_string();
    let (code, at) = line.split_once('@').unwrap_or((line.as_str(), "-"));
    let norm = pair::normalize(code).ok_or_else(not_a_code)?;
    write_out(&format!(
        "{}\t{}\n",
        pair::format_code(&norm),
        if at.is_empty() { "-" } else { at }
    ))
}

/// The calling side: the claim request for the typed code.
fn request() -> Result<()> {
    let fields = stdin_fields()?;
    let body = pair::claim_request(
        &norm_from(&fields)?,
        text(&fields, "name"),
        text(&fields, "hostkey"),
    )?;
    write_out(&format!("{body}\n"))
}

/// The calling side: opens the answer of a claim.
fn open() -> Result<()> {
    let fields = stdin_fields()?;
    let norm = norm_from(&fields)?;
    let answer: Value = serde_json::from_str(text(&fields, "answer")).unwrap_or(Value::Null);
    let inner =
        pair::open_claim(&norm, text(&fields, "request").as_bytes(), &answer).ok_or_else(|| {
            Error::Refused(
                "the answer does not open: wrong code, or not the server that made it".into(),
            )
        })?;
    write_out(&opened_lines(&inner))
}

/// The opened answer as `key<TAB>value` lines, with the fingerprint of the host key.
fn opened_lines(inner: &Value) -> String {
    let fingerprint = pair::fingerprint(text(inner, "hostkey")).unwrap_or_else(|| "-".into());
    let mut lines = String::new();
    for key in ["server", "host", "share", "login", "domain", "password"] {
        let _ = writeln!(lines, "{key}\t{}", text(inner, key));
    }
    let _ = write!(
        lines,
        "hostkey\t{}\nfingerprint\t{fingerprint}\n",
        text(inner, "hostkey")
    );
    lines
}

/// The reverse direction: the push body for a typed receive code.
fn push() -> Result<()> {
    let fields = stdin_fields()?;
    let norm = norm_from(&fields)?;
    let inner = Inner::from_json(&fields)
        .ok_or_else(|| Error::Refused("the inner document is not valid".into()))?;
    let body = pair::push_body(&norm, &inner, &mut OsRandom)?;
    write_out(&format!("{body}\n"))
}
