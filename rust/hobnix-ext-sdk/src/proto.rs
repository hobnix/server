//! Framing shared by both protocols: one JSON object per line, `v: 1`, at most 1 MiB per line.

use std::io::{self, BufRead, Read, Write};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::Event;

pub const VERSION: u32 = 1;
/// Longest line either side may write (ADR 0010 rule 5, ADR 0011 rule 4).
pub const MAX_LINE: usize = 1 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EventLevel {
    Info,
    Warn,
    Error,
}

/// The writing half: a clonable handle so a service can write from several threads. Every message is one line, flushed at once.
#[derive(Clone)]
pub(crate) struct Out(Arc<Mutex<Box<dyn Write + Send>>>);

impl Out {
    pub(crate) fn new(w: impl Write + Send + 'static) -> Self {
        Out(Arc::new(Mutex::new(Box::new(w))))
    }

    pub(crate) fn send(&self, mut msg: Map<String, Value>) -> io::Result<()> {
        msg.insert("v".into(), json!(VERSION));
        let mut line = serde_json::to_string(&Value::Object(msg)).map_err(io::Error::other)?;
        if line.len() + 1 > MAX_LINE {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "message longer than 1 MiB"));
        }
        line.push('\n');
        let mut w = self.0.lock().unwrap_or_else(|p| p.into_inner());
        w.write_all(line.as_bytes())?;
        w.flush()
    }

    pub(crate) fn typed(&self, ty: &str, fields: Value) -> io::Result<()> {
        let mut m = match fields {
            Value::Object(m) => m,
            _ => Map::new(),
        };
        m.insert("type".into(), json!(ty));
        self.send(m)
    }

    pub(crate) fn log(&self, level: LogLevel, text: &str) -> io::Result<()> {
        self.typed("log", json!({"level": level, "text": cut(text, 1000)}))
    }

    /// `ty` is `event` (command) or `emit` (service).
    pub(crate) fn event(&self, ty: &str, ev: &Event) -> io::Result<()> {
        if !valid_kind(&ev.kind) {
            let why = "event kind must look like pkg.<package>.<kind>";
            return Err(io::Error::new(io::ErrorKind::InvalidInput, why));
        }
        let mut f = json!({"kind": ev.kind, "subject": ev.subject});
        if let Some(t) = &ev.text {
            f["text"] = json!(t);
        }
        if let Some(l) = ev.level {
            f["level"] = json!(l);
        }
        if let Some(p) = &ev.payload {
            f["payload"] = Value::Object(p.clone());
        }
        self.typed(ty, f)
    }
}

/// Cut to at most `max` characters (the schema's maxLength counts characters).
pub(crate) fn cut(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

/// One line of English text: line breaks become spaces.
pub(crate) fn one_line(s: &str) -> String {
    s.split(['\n', '\r']).map(str::trim).filter(|p| !p.is_empty()).collect::<Vec<_>>().join(" ")
}

/// `^pkg\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$`
pub(crate) fn valid_kind(kind: &str) -> bool {
    let mut parts = kind.split('.');
    let ok = |p: &str| {
        let mut c = p.chars();
        matches!(c.next(), Some('a'..='z')) && c.all(|c| matches!(c, 'a'..='z' | '0'..='9' | '-'))
    };
    matches!((parts.next(), parts.next(), parts.next(), parts.next()),
        (Some("pkg"), Some(a), Some(b), None) if ok(a) && ok(b))
}

/// What reading one line gave.
pub(crate) enum Line {
    Eof,
    TooLong,
    Text(String),
}

/// Read one line of at most [`MAX_LINE`] bytes (without the newline).
pub(crate) fn read_line(r: &mut impl BufRead) -> io::Result<Line> {
    let mut buf = Vec::new();
    let n = r.by_ref().take(MAX_LINE as u64 + 1).read_until(b'\n', &mut buf)?;
    if n == 0 {
        return Ok(Line::Eof);
    }
    if buf.last() == Some(&b'\n') {
        buf.pop();
        if buf.last() == Some(&b'\r') {
            buf.pop();
        }
    } else if buf.len() > MAX_LINE {
        return Ok(Line::TooLong);
    }
    if buf.len() > MAX_LINE {
        return Ok(Line::TooLong);
    }
    Ok(Line::Text(String::from_utf8_lossy(&buf).into_owned()))
}
