//! Command extensions (ADR 0010): one process per call, one request on stdin, `progress`/`log`/`event` lines and exactly one `result` on
//! stdout (docs/api/ext-protocol-v1.schema.json). The base types (`Ctx`, `Event`, `LogLevel`) are in `hobnix-pkg`.
//!
//! ```no_run
//! use hobnix_pkg_command::{Success, run};
//!
//! fn main() -> std::process::ExitCode {
//!     run(|req, ctx| {
//!         let _ = ctx.progress(Some(0.5), "halfway");
//!         Ok(Success::text(format!("hello {}", req.argv.join(" "))))
//!     })
//! }
//! ```
//!
//! The handler gets a `&dyn Ctx` (a trait object, not a type parameter: a closure cannot be generic over its argument, so a generic
//! `run` would force every handler into a named generic fn, and the dynamic call costs nothing next to the write of a line).
//!
//! With the feature `macros`, a command is a function with the attribute [`command`], and [`commands!`] makes the dispatch and the
//! `commands.tsv` rows from the list of them, so the rows cannot drift from the code:
//!
//! ```
//! # #[cfg(feature = "macros")] mod demo {
//! use hobnix_pkg_command::{Args, Commands, Ctx, Failure, Success, command, commands};
//!
//! #[derive(Args)]
//! struct CountArgs {
//!     /// how far to count
//!     n: u32,
//! }
//!
//! #[command(name = "count", reads, help = "count to n", help_de = "zählt bis n")]
//! fn count(ctx: &dyn Ctx, args: CountArgs) -> Result<Success, Failure> {
//!     let _ = ctx.progress(Some(1.0), "done");
//!     Ok(Success::text(args.n.to_string()))
//! }
//!
//! fn commands() -> Commands {
//!     commands!(package = "demo", script = "@/bin/demo", count)
//! }
//!
//! fn main() -> std::process::ExitCode {
//!     commands().run()
//! }
//! # }
//! ```
//!
//! A package that writes its `commands.tsv` rows by hand keeps using [`run`] and does not build the macro crates.

#[cfg(feature = "macros")]
mod args;
#[cfg(feature = "macros")]
mod table;

#[cfg(feature = "macros")]
pub use args::{ArgKind, ArgSpec, Args};
/// The host side a handler talks to (re-exported from `hobnix-pkg`, so a command needs only this crate).
pub use hobnix_pkg::Ctx;
#[cfg(feature = "macros")]
pub use hobnix_pkg_macros::{Args, command, commands};
#[cfg(feature = "macros")]
pub use table::{Command, Commands, Drift, TABLE_START};

/// What the code of the macros reaches; not part of the public API.
#[cfg(feature = "macros")]
#[doc(hidden)]
pub mod __private {
    pub use crate::args::{check_count, optional, parse_for, required, rest};
    pub use crate::table::{Row, table, table_len};
    pub use crate::{ArgKind, ArgSpec, Args, Command, Commands, Failure, Request, Success};
    pub use hobnix_pkg::Ctx;

    /// One argument (for `#[derive(Args)]`).
    pub const fn arg(
        name: &'static str,
        kind: ArgKind,
        type_name: &'static str,
        help: &'static str,
    ) -> ArgSpec {
        ArgSpec {
            name,
            kind,
            type_name,
            help,
        }
    }
}

use std::io::{self, BufRead, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::process::ExitCode;
use std::sync::Arc;

use hobnix_pkg::integrations::Integration;
use hobnix_pkg::wire::command::{
    FromCore, FromExtension, Outcome, Progress, ResultCode, ResultError,
};
use hobnix_pkg::wire::{self, Decoded, Log, ProtocolError, Writer};
use hobnix_pkg::{ErrorKind, Event, LogLevel, Secret, VERSION};
use serde_json::Value;

pub use hobnix_pkg::Lang;
pub use hobnix_pkg::wire::command::{Caller, Request};

/// Error codes an extension may answer with. `timeout` and `protocol_error` belong to the core; `unsupported_version` is answered
/// by [`run`] itself.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    /// `failed`: the work could not be done.
    Failed,
    /// `not_found`: no such command or thing.
    NotFound,
    /// `bad_request`: the arguments are refused.
    BadRequest,
    /// `cancelled`: the call was stopped.
    Cancelled,
}

impl From<ErrorCode> for ResultCode {
    fn from(c: ErrorCode) -> Self {
        match c {
            ErrorCode::Failed => ResultCode::Failed,
            ErrorCode::NotFound => ResultCode::NotFound,
            ErrorCode::BadRequest => ResultCode::BadRequest,
            ErrorCode::Cancelled => ResultCode::Cancelled,
        }
    }
}

/// A failed call: a code the interface translates, and one English line.
#[non_exhaustive]
#[derive(Debug, Clone, PartialEq)]
pub struct Failure {
    /// The code.
    pub code: ErrorCode,
    /// One English line (line breaks become spaces when it is written).
    pub message: String,
}

impl Failure {
    /// A failure with `code` and `message`.
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Failure {
            code,
            message: message.into(),
        }
    }
    /// `failed` with `message`.
    pub fn failed(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Failed, message)
    }
    /// `not_found` with `message`.
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::NotFound, message)
    }
    /// `bad_request` with `message`.
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadRequest, message)
    }
}

impl From<hobnix_pkg::Error> for Failure {
    /// The code of the error's kind (a kind this version does not know is `failed`) and the error with its causes as the message.
    fn from(e: hobnix_pkg::Error) -> Self {
        let code = match e.kind() {
            ErrorKind::BadRequest => ErrorCode::BadRequest,
            ErrorKind::NotFound => ErrorCode::NotFound,
            ErrorKind::Cancelled => ErrorCode::Cancelled,
            _ => ErrorCode::Failed,
        };
        Failure::new(code, e.chain())
    }
}

/// A successful call: optional structured `data` and optional `text` for a person.
#[non_exhaustive]
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Success {
    /// Any JSON; its shape belongs to the command.
    pub data: Option<Value>,
    /// What a person at a terminal is shown.
    pub text: Option<String>,
}

impl Success {
    /// Only text.
    pub fn text(text: impl Into<String>) -> Self {
        Success {
            data: None,
            text: Some(text.into()),
        }
    }
    /// Only data.
    pub fn data(data: Value) -> Self {
        Success {
            data: Some(data),
            text: None,
        }
    }
    /// Add the text.
    #[must_use]
    pub fn with_text(mut self, text: impl Into<String>) -> Self {
        self.text = Some(text.into());
        self
    }
}

/// The stdin/stdout side of [`Ctx`] for a command: `progress`, `log` and `event` lines on stdout.
struct StdioCtx {
    out: Writer,
}

/// A write error as the `io::Error` the [`Ctx`] methods return: a refused message is `InvalidInput`.
fn to_io(e: ProtocolError) -> io::Error {
    match e {
        ProtocolError::Io(e) => e,
        ProtocolError::Encode(e) => io::Error::other(e),
        e => io::Error::new(io::ErrorKind::InvalidInput, e.to_string()),
    }
}

/// `ev` when its kind has the shape `pkg.<package>.<kind>`; `InvalidInput` otherwise, before anything is written.
fn checked_event(ev: &Event) -> io::Result<Event> {
    if wire::is_event_kind(&ev.kind) {
        Ok(ev.clone())
    } else {
        let why = "event kind must look like pkg.<package>.<kind>";
        Err(io::Error::new(io::ErrorKind::InvalidInput, why))
    }
}

impl StdioCtx {
    fn send(&self, msg: &FromExtension) -> io::Result<()> {
        self.out.send(msg).map_err(to_io)
    }
}

impl Ctx for StdioCtx {
    fn credential(&self, name: &str, provider: &str) -> Option<Secret> {
        hobnix_pkg::credentials::credential_for(name, provider)
    }
    fn integrations(&self) -> &[Integration] {
        &[]
    }
    fn emit(&self, ev: &Event) -> io::Result<()> {
        self.send(&FromExtension::Event(checked_event(ev)?))
    }
    fn log(&self, level: LogLevel, text: &str) -> io::Result<()> {
        self.send(&FromExtension::Log(Log::new(level, text)))
    }
    fn progress(&self, fraction: Option<f64>, text: &str) -> io::Result<()> {
        self.send(&FromExtension::Progress(Progress::new(fraction, text)))
    }
    fn shared(&self) -> Arc<dyn Ctx> {
        Arc::new(StdioCtx {
            out: self.out.clone(),
        })
    }
}

/// Run the extension against stdin/stdout and return the process exit code (0 for `ok`, 1 otherwise, as ADR 0010 rule 4 demands).
/// A panic in the handler becomes `failed`.
pub fn run<F>(handler: F) -> ExitCode
where
    F: FnOnce(&Request, &dyn Ctx) -> Result<Success, Failure>,
{
    let stdin = io::stdin();
    let code = run_with(&mut stdin.lock(), io::stdout(), handler);
    ExitCode::from(code)
}

/// [`run`] over any reader and writer (for tests). Returns the exit code.
pub fn run_with<F>(input: &mut impl BufRead, output: impl Write + Send + 'static, handler: F) -> u8
where
    F: FnOnce(&Request, &dyn Ctx) -> Result<Success, Failure>,
{
    let out = Writer::new(output);
    let req = match read_request(input) {
        Ok(r) => r,
        Err(e) => return fail(&out, e),
    };
    let ctx = StdioCtx { out: out.clone() };
    let outcome = catch_unwind(AssertUnwindSafe(|| handler(&req, &ctx)))
        .unwrap_or_else(|_| Err(Failure::failed("the extension crashed")));
    match outcome {
        Ok(s) => {
            let result = Outcome::Ok {
                data: s.data,
                text: s.text,
            };
            match out.send(&FromExtension::Result(result)) {
                Ok(()) => 0,
                // a result that cannot be written (too long): say so instead of leaving the core without one
                Err(e) => {
                    let msg = format!("cannot write the result: {}", to_io(e));
                    fail(&out, ResultError::new(ResultCode::Failed, &msg))
                }
            }
        }
        Err(f) => fail(&out, ResultError::new(f.code.into(), &f.message)),
    }
}

/// The request line, or the error result that answers a line that is not one.
fn read_request(input: &mut impl BufRead) -> Result<Request, ResultError> {
    let bad = |m: &str| ResultError::new(ResultCode::BadRequest, m);
    let line = match wire::read_line(input) {
        Ok(Some(l)) => l,
        Ok(None) => return Err(bad("no request on stdin")),
        Err(ProtocolError::TooLong) => return Err(bad("request longer than 1 MiB")),
        Err(e) => return Err(bad(&format!("cannot read the request: {}", to_io(e)))),
    };
    match wire::decode::<FromCore>(&line) {
        Ok(Decoded::Message(FromCore::Request(r))) => Ok(r),
        Err(ProtocolError::NotJson(_)) => Err(bad("the request is not JSON")),
        Err(ProtocolError::UnsupportedVersion(_)) => {
            let msg = "this extension speaks protocol version 1 only";
            Err(ResultError::new(ResultCode::UnsupportedVersion, msg).supported(vec![VERSION]))
        }
        Err(ProtocolError::Invalid { source, .. }) => {
            Err(bad(&format!("invalid request: {source}")))
        }
        _ => Err(bad("the first line must be a request")),
    }
}

fn fail(out: &Writer, error: ResultError) -> u8 {
    let _ = out.send(&FromExtension::Result(Outcome::Err(error)));
    1
}
