//! Command extensions (ADR 0010): one process per call.
//!
//! ```no_run
//! use hobnix_ext_sdk::command::{run, Success};
//!
//! fn main() -> std::process::ExitCode {
//!     run(|req, ctx| {
//!         ctx.progress(Some(0.5), "halfway");
//!         Ok(Success::text(format!("hello {}", req.argv.join(" "))))
//!     })
//! }
//! ```

use std::io::{self, BufRead, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::process::ExitCode;

use serde::Deserialize;
use serde_json::{json, Value};

use crate::proto::{cut, one_line, read_line, Line, Out};
use crate::{Event, LogLevel, VERSION};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Lang {
    En,
    De,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Caller {
    Cli,
    Web,
    Boot,
}

/// The one request line the core writes to stdin.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Request {
    pub id: String,
    /// The words after `hs ext <name>`.
    pub command: Vec<String>,
    /// The arguments after the command words. Never a secret (ADR 0010 rule 9).
    pub argv: Vec<String>,
    pub lang: Lang,
    pub caller: Caller,
    /// The limit the core enforces; a hint only.
    pub timeout_ms: u64,
}

impl Request {
    /// The command words as `&str`, for `match req.words().as_slice() { ["status"] => ..., }`.
    pub fn words(&self) -> Vec<&str> {
        self.command.iter().map(String::as_str).collect()
    }
}

/// Error codes an extension may answer with. `timeout` and `protocol_error` belong to the core; `unsupported_version` is answered
/// by [`run`] itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    Failed,
    NotFound,
    BadRequest,
    Cancelled,
}

impl ErrorCode {
    fn as_str(self) -> &'static str {
        match self {
            ErrorCode::Failed => "failed",
            ErrorCode::NotFound => "not_found",
            ErrorCode::BadRequest => "bad_request",
            ErrorCode::Cancelled => "cancelled",
        }
    }
}

/// A failed call: a code the interface translates, and one English line.
#[derive(Debug, Clone, PartialEq)]
pub struct Failure {
    pub code: ErrorCode,
    pub message: String,
}

impl Failure {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Failure {
            code,
            message: message.into(),
        }
    }
    pub fn failed(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Failed, message)
    }
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::NotFound, message)
    }
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadRequest, message)
    }
}

/// A successful call: optional structured `data` and optional `text` for a person.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Success {
    pub data: Option<Value>,
    pub text: Option<String>,
}

impl Success {
    pub fn text(text: impl Into<String>) -> Self {
        Success {
            data: None,
            text: Some(text.into()),
        }
    }
    pub fn data(data: Value) -> Self {
        Success {
            data: Some(data),
            text: None,
        }
    }
    pub fn with_text(mut self, text: impl Into<String>) -> Self {
        self.text = Some(text.into());
        self
    }
}

/// Handle for the messages an extension may send before its result. Write failures are returned, not hidden; a call that has no
/// use for them can ignore the result.
pub struct Ctx {
    out: Out,
}

impl Ctx {
    /// `fraction` is clamped to 0..=1; `text` is cut to 200 characters.
    pub fn progress(&self, fraction: Option<f64>, text: &str) -> io::Result<()> {
        let mut f = json!({"text": cut(text, 200)});
        if let Some(x) = fraction.filter(|x| x.is_finite()) {
            f["fraction"] = json!(x.clamp(0.0, 1.0));
        }
        self.out.typed("progress", f)
    }
    /// `text` is cut to 1000 characters. Not for secrets.
    pub fn log(&self, level: LogLevel, text: &str) -> io::Result<()> {
        self.out.log(level, text)
    }
    /// Ask the core to write an event. Fails with `InvalidInput` for a kind that is not `pkg.<package>.<kind>`.
    pub fn event(&self, ev: &Event) -> io::Result<()> {
        self.out.event("event", ev)
    }
}

/// Run the extension against stdin/stdout and return the process exit code (0 for `ok`, 1 otherwise, as ADR 0010 rule 4 demands).
/// A panic in the handler becomes `failed`.
pub fn run<F>(handler: F) -> ExitCode
where
    F: FnOnce(&Request, &Ctx) -> Result<Success, Failure>,
{
    let stdin = io::stdin();
    let code = run_with(&mut stdin.lock(), io::stdout(), handler);
    ExitCode::from(code)
}

/// [`run`] over any reader and writer (for tests). Returns the exit code.
pub fn run_with<F>(input: &mut impl BufRead, output: impl Write + Send + 'static, handler: F) -> u8
where
    F: FnOnce(&Request, &Ctx) -> Result<Success, Failure>,
{
    let out = Out::new(output);
    let line = match read_line(input) {
        Ok(Line::Text(l)) => l,
        Ok(Line::Eof) => return fail(&out, "bad_request", "no request on stdin", None),
        Ok(Line::TooLong) => return fail(&out, "bad_request", "request longer than 1 MiB", None),
        Err(e) => {
            return fail(
                &out,
                "bad_request",
                &format!("cannot read the request: {e}"),
                None,
            )
        }
    };
    let value: Value = match serde_json::from_str(&line) {
        Ok(v) => v,
        Err(_) => return fail(&out, "bad_request", "the request is not JSON", None),
    };
    if value.get("v").and_then(Value::as_u64) != Some(VERSION as u64) {
        let msg = "this extension speaks protocol version 1 only";
        return fail(&out, "unsupported_version", msg, Some(json!([VERSION])));
    }
    let req: Request = match value.get("type").and_then(Value::as_str) {
        Some("request") => match serde_json::from_value(value) {
            Ok(r) => r,
            Err(e) => return fail(&out, "bad_request", &format!("invalid request: {e}"), None),
        },
        _ => {
            return fail(
                &out,
                "bad_request",
                "the first line must be a request",
                None,
            )
        }
    };
    let ctx = Ctx { out: out.clone() };
    let outcome = catch_unwind(AssertUnwindSafe(|| handler(&req, &ctx)))
        .unwrap_or_else(|_| Err(Failure::failed("the extension crashed")));
    match outcome {
        Ok(s) => {
            let mut f = json!({"ok": true});
            if let Some(d) = s.data {
                f["data"] = d;
            }
            if let Some(t) = s.text {
                f["text"] = json!(t);
            }
            match out.typed("result", f) {
                Ok(()) => 0,
                // a result that cannot be written (too long): say so instead of leaving the core without one
                Err(e) => fail(
                    &out,
                    "failed",
                    &format!("cannot write the result: {e}"),
                    None,
                ),
            }
        }
        Err(e) => fail(&out, e.code.as_str(), &e.message, None),
    }
}

fn fail(out: &Out, code: &str, message: &str, supported: Option<Value>) -> u8 {
    let mut err = json!({"code": code, "message": one_line(message)});
    if let Some(s) = supported {
        err["supported"] = s;
    }
    let _ = out.typed("result", json!({"ok": false, "error": err}));
    1
}
