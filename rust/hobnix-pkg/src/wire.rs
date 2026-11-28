//! The wire messages of both protocols, one JSON object per line with `"v": 1`, at most 1 MiB per line.
//!
//! [`command`] holds the messages of the command protocol (ADR 0010, docs/api/ext-protocol-v1.schema.json), [`service`] those of the
//! service protocol (ADR 0011, docs/api/ext-service-v1.schema.json). Every message type can be read and written, so the extension side
//! (the runners of `hobnix-pkg-command` and `hobnix-pkg-service`) and a host share one definition.
//!
//! [`encode`] writes one message as a line: the fields, `type` and `v`, with the keys of every object sorted (so the bytes do not depend
//! on how `serde_json` was built: cargo turns its `preserve_order` feature on for every crate of a build once one crate asks for it).
//! [`decode`] reads one line: it checks `v`, reads `type` and returns [`Decoded::Unknown`] for a type that this version does not know
//! (ADR 0010 rule 3: an unknown type is ignored, so the protocol can grow without a new `v`).
use std::fmt;
use std::io::{self, BufRead, Read, Write};
use std::sync::{Arc, Mutex};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub mod command;
pub mod service;

/// The protocol version both sides speak.
pub const VERSION: u32 = 1;
/// Longest line either side may write, newline included (ADR 0010 rule 5, ADR 0011 rule 4).
pub const MAX_LINE: usize = 1 << 20;
/// Longest `text` of a `log` message, in characters.
pub const LOG_TEXT_MAX: usize = 1000;

/// Level of a `log` message.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    /// Detail for a developer.
    Debug,
    /// Normal operation.
    Info,
    /// Something a person should look at.
    Warn,
    /// Something failed.
    Error,
}

/// Level of an event the extension asks the core to write.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EventLevel {
    /// Normal operation.
    Info,
    /// Something a person should look at.
    Warn,
    /// Something failed.
    Error,
}

/// The language of the person behind a call (`request.lang`, `init.lang`).
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Lang {
    /// English.
    En,
    /// German.
    De,
    /// A language this version does not know (a newer core); answer in English. It cannot be written.
    #[serde(other, skip_serializing)]
    Other,
}

/// A `log` line, in both protocols.
#[non_exhaustive]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Log {
    /// The level.
    pub level: LogLevel,
    /// One line, at most [`LOG_TEXT_MAX`] characters.
    pub text: String,
}

impl Log {
    /// A log line; `text` is cut to [`LOG_TEXT_MAX`] characters.
    pub fn new(level: LogLevel, text: &str) -> Self {
        Log {
            level,
            text: truncate(text, LOG_TEXT_MAX),
        }
    }
}

/// A message enum of one direction of one protocol ([`command::FromCore`], [`command::FromExtension`], [`service::FromCore`],
/// [`service::FromService`]). Its `Serialize` writes the fields and `type`.
pub trait Message: Serialize + Sized {
    /// The message of type `message_type` from the whole line as JSON (it still holds `v` and `type`, which the message types ignore);
    /// `Ok(None)` for a type this enum does not know. Fails with [`ProtocolError::Invalid`] when the fields do not fit the type.
    fn from_typed(message_type: &str, value: Value) -> Result<Option<Self>, ProtocolError>;
}

/// What [`decode`] read.
#[derive(Debug, Clone, PartialEq)]
pub enum Decoded<M> {
    /// A message of a type this version knows.
    Message(M),
    /// A message of a type this version does not know, with its `type`; ignore it.
    Unknown(String),
}

/// Why a line could not be read or written.
#[non_exhaustive]
#[derive(Debug)]
pub enum ProtocolError {
    /// The line is not JSON.
    NotJson(serde_json::Error),
    /// `v` is missing or not [`VERSION`]; the value found, if it is a number.
    UnsupportedVersion(Option<u64>),
    /// The message has no `type`.
    MissingType,
    /// The fields do not fit the message type `message_type`.
    Invalid {
        /// The `type` of the line.
        message_type: String,
        /// What serde found.
        source: serde_json::Error,
    },
    /// The line is longer than [`MAX_LINE`].
    TooLong,
    /// The message cannot be written as JSON (a value that serde refuses, such as [`Lang::Other`]).
    Encode(serde_json::Error),
    /// Reading or writing failed.
    Io(io::Error),
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProtocolError::NotJson(_) => f.write_str("a line that is not JSON"),
            ProtocolError::UnsupportedVersion(_) => {
                write!(
                    f,
                    "unsupported protocol version (this side speaks {VERSION})"
                )
            }
            ProtocolError::MissingType => f.write_str("a message without a type"),
            ProtocolError::Invalid { message_type, .. } => write!(f, "invalid {message_type}"),
            ProtocolError::TooLong => f.write_str("message longer than 1 MiB"),
            ProtocolError::Encode(_) => f.write_str("the message cannot be written as JSON"),
            ProtocolError::Io(_) => f.write_str("cannot read or write a line"),
        }
    }
}

impl std::error::Error for ProtocolError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ProtocolError::NotJson(e)
            | ProtocolError::Encode(e)
            | ProtocolError::Invalid { source: e, .. } => Some(e),
            ProtocolError::Io(e) => Some(e),
            _ => None,
        }
    }
}

/// One message as a line without the newline: its fields, `type` and `v`, keys sorted. Fails with [`ProtocolError::TooLong`] when the
/// line with its newline is longer than [`MAX_LINE`], with [`ProtocolError::Encode`] when serde refuses a value.
pub fn encode<M: Message>(msg: &M) -> Result<String, ProtocolError> {
    let mut value = serde_json::to_value(msg).map_err(ProtocolError::Encode)?;
    if let Value::Object(m) = &mut value {
        m.insert("v".into(), Value::from(VERSION));
    }
    let line = serde_json::to_string(&Sorted(&value)).map_err(ProtocolError::Encode)?;
    if line.len() >= MAX_LINE {
        return Err(ProtocolError::TooLong);
    }
    Ok(line)
}

/// One line (without its newline) as a message: checks `v` first, then `type`. See [`ProtocolError`] for the failures.
pub fn decode<M: Message>(line: &str) -> Result<Decoded<M>, ProtocolError> {
    let value: Value = serde_json::from_str(line).map_err(ProtocolError::NotJson)?;
    let version = value.get("v").and_then(Value::as_u64);
    if version != Some(u64::from(VERSION)) {
        return Err(ProtocolError::UnsupportedVersion(version));
    }
    let Some(ty) = value.get("type").and_then(Value::as_str).map(str::to_owned) else {
        return Err(ProtocolError::MissingType);
    };
    Ok(match M::from_typed(&ty, value)? {
        Some(m) => Decoded::Message(m),
        None => Decoded::Unknown(ty),
    })
}

/// The fields of `value` as `T`, for [`Message::from_typed`].
pub(crate) fn fields<T: DeserializeOwned>(
    message_type: &str,
    value: Value,
) -> Result<T, ProtocolError> {
    serde_json::from_value(value).map_err(|source| ProtocolError::Invalid {
        message_type: message_type.to_owned(),
        source,
    })
}

/// The writing half of a protocol: a clonable handle, so a service can write from several threads. Every message is one line, flushed
/// at once.
#[derive(Clone)]
pub struct Writer(Arc<Mutex<Box<dyn Write + Send>>>);

impl fmt::Debug for Writer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Writer").finish_non_exhaustive()
    }
}

impl Writer {
    /// A writer to `w` (stdout of an extension, stdin of a child for a host).
    pub fn new(w: impl Write + Send + 'static) -> Self {
        Writer(Arc::new(Mutex::new(Box::new(w))))
    }

    /// Write `msg` as one line ([`encode`]) and flush. Fails as [`encode`] does, or with [`ProtocolError::Io`].
    pub fn send<M: Message>(&self, msg: &M) -> Result<(), ProtocolError> {
        let mut line = encode(msg)?;
        line.push('\n');
        let mut w = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        w.write_all(line.as_bytes()).map_err(ProtocolError::Io)?;
        w.flush().map_err(ProtocolError::Io)
    }
}

/// Read one line of at most [`MAX_LINE`] bytes; the newline (and a `\r` before it) is cut, invalid UTF-8 is replaced. `Ok(None)` at
/// the end of the input. Fails with [`ProtocolError::TooLong`] or [`ProtocolError::Io`].
pub fn read_line(r: &mut impl BufRead) -> Result<Option<String>, ProtocolError> {
    let mut buf = Vec::new();
    let n = r
        .by_ref()
        .take(MAX_LINE as u64 + 1)
        .read_until(b'\n', &mut buf)
        .map_err(ProtocolError::Io)?;
    if n == 0 {
        return Ok(None);
    }
    if buf.last() == Some(&b'\n') {
        buf.pop();
        if buf.last() == Some(&b'\r') {
            buf.pop();
        }
    }
    if buf.len() > MAX_LINE {
        return Err(ProtocolError::TooLong);
    }
    Ok(Some(String::from_utf8_lossy(&buf).into_owned()))
}

/// A JSON value written with the keys of every object in sorted order (see the module text).
struct Sorted<'a>(&'a Value);

impl Serialize for Sorted<'_> {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        match self.0 {
            Value::Object(m) => {
                let mut entries: Vec<(&String, &Value)> = m.iter().collect();
                entries.sort_unstable_by(|a, b| a.0.cmp(b.0));
                let mut map = s.serialize_map(Some(entries.len()))?;
                for (k, v) in entries {
                    map.serialize_entry(k, &Sorted(v))?;
                }
                map.end()
            }
            Value::Array(a) => s.collect_seq(a.iter().map(Sorted)),
            v => v.serialize(s),
        }
    }
}

/// `s` cut to at most `max` characters (the schemas' `maxLength` counts characters).
pub fn truncate(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

/// One line of text: line breaks become spaces, blank parts go.
pub fn one_line(s: &str) -> String {
    s.split(['\n', '\r'])
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// `kind` has the shape of a package event kind: `^pkg\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$`.
pub fn is_event_kind(kind: &str) -> bool {
    let mut parts = kind.split('.');
    let ok = |p: &str| {
        let mut c = p.chars();
        matches!(c.next(), Some('a'..='z')) && c.all(|c| matches!(c, 'a'..='z' | '0'..='9' | '-'))
    };
    matches!((parts.next(), parts.next(), parts.next(), parts.next()),
        (Some("pkg"), Some(a), Some(b), None) if ok(a) && ok(b))
}

#[cfg(test)]
mod tests;
