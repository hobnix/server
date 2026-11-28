//! The lines that are not a command's answer: the version, the probe word, usage lines, errors and the debug line.
//!
//! Rust ignores SIGPIPE, so a closed pipe is a write error. A line that cannot be written ends the program with the exit code of a
//! panic, which is what `println!` and `eprintln!` did here: a caller that lost the line must not see a success or a refusal.

use std::fmt::Display;
use std::io::{self, Write};

/// The exit code of a panicking Rust program.
pub(crate) const EXIT_OUTPUT_LOST: u8 = 101;

/// Writes one line to standard error.
pub(crate) fn error_line(line: impl Display) -> io::Result<()> {
    writeln!(io::stderr().lock(), "{line}")
}

/// Writes one line to standard output. When that fails, a line on standard error says why.
pub(crate) fn line(line: impl Display) -> io::Result<()> {
    writeln!(io::stdout().lock(), "{line}").inspect_err(|reason| {
        // standard error may be gone too: then there is nobody left to tell
        let _ = error_line(format_args!("failed printing to stdout: {reason}"));
    })
}

/// The exit code of a command that ends with this write: `code` when the line was written.
pub(crate) fn exit_with(written: io::Result<()>, code: u8) -> u8 {
    written.map_or(EXIT_OUTPUT_LOST, |()| code)
}
