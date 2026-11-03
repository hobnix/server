//! Adapter of the strangler: the only place that writes to the terminal.

use hobnix_core::log::{self, Level};
use hobnix_core::Error;
use std::process::ExitCode;

fn run(args: &[String]) -> hobnix_core::Result<()> {
    match args.first().map(String::as_str) {
        None | Some("--version") => {
            println!("hobnix {}", hobnix_core::version());
            Ok(())
        }
        Some(other) => Err(Error::Refused(format!("unknown subcommand: {other}"))),
    }
}

fn main() -> ExitCode {
    let max = Level::from_env();
    if log::enabled(Level::Debug, max) {
        eprintln!(
            "{}",
            log::format(
                Level::Debug,
                "start",
                &[("version", hobnix_core::version())]
            )
        );
    }
    let args: hobnix_core::Result<Vec<String>> = std::env::args_os()
        .skip(1)
        .map(|a| {
            a.into_string()
                .map_err(|_| Error::Refused("argument is not valid UTF-8".to_string()))
        })
        .collect();
    match args.and_then(|a| run(&a)) {
        Ok(()) => ExitCode::from(hobnix_core::EXIT_OK),
        Err(e) => {
            eprintln!("hobnix: {e}");
            ExitCode::from(e.exit_code())
        }
    }
}
