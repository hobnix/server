//! Adapter of the strangler: the only crate that writes to the terminal.

use hobnix_core::log::{self, Level};
use hobnix_core::{EXIT_OK, Error};
use std::process::ExitCode;

mod events;
mod jobs;
mod output;
mod pair;
mod secrets;

fn run(args: &[String]) -> hobnix_core::Result<u8> {
    let rest = args.get(1..).unwrap_or_default();
    match args.first().map(String::as_str) {
        None | Some("--version") => {
            let written = output::line(format_args!("hobnix {}", hobnix_core::version()));
            Ok(output::exit_with(written, EXIT_OK))
        }
        Some("event-emit") => events::run(rest),
        Some("job-record") => jobs::run(rest),
        Some("secrets") => secrets::run(rest),
        Some("remote-codes") => pair::codes(rest),
        Some("remote-claim") => pair::claim(rest),
        Some("remote-accept") => pair::accept(rest),
        Some("pair") => pair::run(rest),
        Some(other) => Err(Error::Refused(format!("unknown subcommand: {other}"))),
    }
}

fn main() -> ExitCode {
    if log::enabled(Level::Debug, Level::from_env()) {
        let line = log::format(
            Level::Debug,
            "start",
            &[("version", hobnix_core::version())],
        );
        // the command does not run when its first line is already lost
        if output::error_line(line).is_err() {
            return ExitCode::from(output::EXIT_OUTPUT_LOST);
        }
    }
    let args: hobnix_core::Result<Vec<String>> = std::env::args_os()
        .skip(1)
        .map(|a| {
            a.into_string()
                .map_err(|_| Error::Refused("argument is not valid UTF-8".to_string()))
        })
        .collect();
    match args.and_then(|a| run(&a)) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            let written = output::error_line(format_args!("hobnix: {e}"));
            ExitCode::from(output::exit_with(written, e.exit_code()))
        }
    }
}
