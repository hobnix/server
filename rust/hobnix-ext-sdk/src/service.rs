//! Service extensions (ADR 0011): one supervised process, JSON lines both ways.
//!
//! Implement [`Service`] and call [`run`]. The SDK reads `init`, calls [`Service::start`], sends `ready`, then loops: it calls
//! [`Service::tick`] and sends `health` at least every `health_interval` (half of it, so one late tick is not a missed heartbeat),
//! passes each `event` to [`Service::on_event`] and sends the `ack` when that returns `Ok`, and returns when the core sends `shutdown`
//! or closes stdin. Events are delivered at least once: `on_event` must be idempotent (use `EventRow::id` as the key).
//!
//! A slow `on_event` or `tick` delays the heartbeat; keep them short or hand work to your own threads (the [`Ctx`] is `Clone + Send`).

use std::io::{self, BufRead, Write};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{json, Value};

use crate::command::Lang;
use crate::proto::{cut, read_line, Line, Out};
use crate::{Event, LogLevel, VERSION};

/// First message from the core.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Init {
    pub name: String,
    pub lang: Lang,
    /// Event kind globs from the manifest; empty for a pure collector.
    pub subscribe: Vec<String>,
    /// Seconds between `health` messages the core expects at most.
    pub health_interval: f64,
}

/// One row of the event log, delivered at least once and in `id` order.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct EventRow {
    pub id: u64,
    pub time: i64,
    pub source: String,
    pub kind: String,
    pub subject: String,
    pub level: String,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub payload: Option<Value>,
}

/// The answer to a heartbeat. `ok: false` marks the service `degraded`; the text is one English line (cut to 200 characters).
#[derive(Debug, Clone, PartialEq)]
pub struct Health {
    pub ok: bool,
    pub text: Option<String>,
}

impl Health {
    pub fn ok() -> Self {
        Health {
            ok: true,
            text: None,
        }
    }
    pub fn degraded(text: impl Into<String>) -> Self {
        Health {
            ok: false,
            text: Some(text.into()),
        }
    }
}

/// Messages a service may send besides the SDK's own (`ready`, `health`, `ack`).
#[derive(Clone)]
pub struct Ctx {
    out: Out,
}

impl Ctx {
    pub fn log(&self, level: LogLevel, text: &str) -> io::Result<()> {
        self.out.log(level, text)
    }
    /// Ask the core to write an event (`emit`). The core allows 50 a minute per service and only kinds of the manifest's `[[events]]`.
    pub fn emit(&self, ev: &Event) -> io::Result<()> {
        self.out.event("emit", ev)
    }
    /// Publish the newest state of `topic` (`[a-z0-9-]{1,60}`); replaces the previous one. At most 256 KiB.
    pub fn snapshot(&self, topic: &str, data: Value) -> io::Result<()> {
        let chars_ok = topic
            .chars()
            .all(|c| matches!(c, 'a'..='z' | '0'..='9' | '-'));
        if !(1..=60).contains(&topic.len()) || !chars_ok {
            let why = "topic must be 1 to 60 characters of a-z, 0-9 and -";
            return Err(io::Error::new(io::ErrorKind::InvalidInput, why));
        }
        let size = serde_json::to_vec(&data).map_err(io::Error::other)?.len();
        if size > 256 << 10 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "snapshot larger than 256 KiB",
            ));
        }
        self.out
            .typed("snapshot", json!({"topic": topic, "data": data}))
    }
}

pub trait Service {
    /// Called once after `init`, before `ready`. An `Err` ends the process with status 1 (the core marks the start failed).
    fn start(&mut self, _init: &Init, _ctx: &Ctx) -> Result<(), String> {
        Ok(())
    }
    /// Handle one event. `Ok` sends the `ack`. `Err` logs the reason, sends no ack and keeps going: the event comes again after a
    /// restart, and the core stops delivering when 100 events are unacknowledged, so a service that cannot handle events should
    /// report `Health::degraded` from [`Service::tick`].
    fn on_event(&mut self, _event: &EventRow, _ctx: &Ctx) -> Result<(), String> {
        Ok(())
    }
    /// Called at startup and then every half `health_interval`: do periodic work (a collector reads and sends a snapshot here) and
    /// say how the service is.
    fn tick(&mut self, _ctx: &Ctx) -> Health {
        Health::ok()
    }
}

/// Run the service against stdin/stdout. Returns the exit code: 0 after `shutdown` or end of stdin, 1 after a protocol error.
pub fn run(service: impl Service) -> std::process::ExitCode {
    let code = run_with(io::BufReader::new(io::stdin()), io::stdout(), service);
    std::process::ExitCode::from(code)
}

enum Msg {
    Event(EventRow),
    Shutdown,
    Eof,
    Bad(String),
}

/// [`run`] over any reader and writer (for tests).
pub fn run_with(
    mut input: impl BufRead + Send + 'static,
    output: impl Write + Send + 'static,
    mut service: impl Service,
) -> u8 {
    let out = Out::new(output);
    let ctx = Ctx { out: out.clone() };
    // Before `ready` only `ready` may be written, so a failure here is reported on stderr only.
    let init: Init = match read_line(&mut input) {
        Ok(Line::Text(l)) => match parse(&l, "init") {
            Ok(v) => v,
            Err(e) => return die(&e),
        },
        Ok(Line::Eof) => return die("stdin closed before init"),
        Ok(Line::TooLong) => return die("init longer than 1 MiB"),
        Err(e) => return die(&format!("cannot read init: {e}")),
    };
    if let Err(e) = service.start(&init, &ctx) {
        return die(&format!("start failed: {e}"));
    }
    if out.typed("ready", json!({})).is_err() {
        return 1;
    }

    let (tx, rx) = mpsc::channel();
    thread::spawn(move || loop {
        let msg = match read_line(&mut input) {
            Ok(Line::Eof) | Err(_) => Msg::Eof,
            Ok(Line::TooLong) => Msg::Bad("line longer than 1 MiB".into()),
            Ok(Line::Text(l)) => match classify(&l) {
                Ok(Some(m)) => m,
                // a type this version does not know: ignored (ADR 0010 rule 3)
                Ok(None) => continue,
                Err(e) => Msg::Bad(e),
            },
        };
        let last = !matches!(msg, Msg::Event(_));
        if tx.send(msg).is_err() || last {
            break;
        }
    });

    let period = Duration::from_secs_f64((init.health_interval / 2.0).clamp(0.05, 150.0));
    let mut next_tick = Instant::now();
    loop {
        if Instant::now() >= next_tick {
            let h = service.tick(&ctx);
            let mut f = json!({"ok": h.ok});
            if let Some(t) = h.text {
                f["text"] = json!(cut(&t, 200));
            }
            if out.typed("health", f).is_err() {
                return 1;
            }
            next_tick = Instant::now() + period;
        }
        match rx.recv_timeout(next_tick.saturating_duration_since(Instant::now())) {
            Ok(Msg::Event(ev)) => match service.on_event(&ev, &ctx) {
                Ok(()) => {
                    if out.typed("ack", json!({"id": ev.id})).is_err() {
                        return 1;
                    }
                }
                Err(e) => {
                    let _ = ctx.log(
                        LogLevel::Error,
                        &format!("event {} not handled: {e}", ev.id),
                    );
                }
            },
            Ok(Msg::Shutdown) | Ok(Msg::Eof) | Err(RecvTimeoutError::Disconnected) => return 0,
            Ok(Msg::Bad(e)) => return die(&e),
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
}

fn die(reason: &str) -> u8 {
    eprintln!("hobnix-ext-sdk: {reason}");
    1
}

fn parse<T: serde::de::DeserializeOwned>(line: &str, ty: &str) -> Result<T, String> {
    let v: Value = serde_json::from_str(line).map_err(|_| "a line that is not JSON".to_string())?;
    if v.get("v").and_then(Value::as_u64) != Some(VERSION as u64) {
        return Err("unsupported protocol version (this SDK speaks 1)".into());
    }
    if v.get("type").and_then(Value::as_str) != Some(ty) {
        return Err(format!("expected a {ty} message"));
    }
    serde_json::from_value(v).map_err(|e| format!("invalid {ty}: {e}"))
}

fn classify(line: &str) -> Result<Option<Msg>, String> {
    let v: Value = serde_json::from_str(line).map_err(|_| "a line that is not JSON".to_string())?;
    if v.get("v").and_then(Value::as_u64) != Some(VERSION as u64) {
        return Err("unsupported protocol version (this SDK speaks 1)".into());
    }
    match v.get("type").and_then(Value::as_str) {
        Some("event") => match serde_json::from_value(v) {
            Ok(e) => Ok(Some(Msg::Event(e))),
            Err(e) => Err(format!("invalid event: {e}")),
        },
        Some("shutdown") => Ok(Some(Msg::Shutdown)),
        // `init` twice or a type from a later minor version: not for this loop
        _ => Ok(None),
    }
}
