//! `hobnix job-record <words>`: the words and flags of scripts/job-record.py, answered by hobnix-core's job store.
//!
//! Exit codes follow job-record.py, not the 0/1/2 scheme of the other commands: every failure is one stderr line
//! `hobnix: <msg>` and exit 1 (`cancelled` exits 1 without a line when the job is not cancelled). The scripts that call it
//! only ever test for zero.

use crate::output;
use arguments::{Arguments, bad, whole_number};
use hobnix_core::jobs::{NewJob, Question, RealSystem, Store};
use hobnix_core::{EXIT_OK, EXIT_REFUSED, Error, Result};
use std::io::Write;

mod arguments;

const DEFAULT_DIR: &str = "/var/lib/hs/jobs";

const NEW_OPTIONS: &[&str] = &[
    "--slug",
    "--desc",
    "--unit",
    "--source",
    "--initiator",
    "--parent",
    "--kind",
];
const WAIT_OPTIONS: &[&str] = &[
    "--seq",
    "--key",
    "--label",
    "--kind",
    "--default",
    "--pattern",
    "--choices",
    "--error",
    "--attempt",
];
const ERROR_OPTIONS: &[&str] = &["--category", "--message", "--code"];
const RESULT_OPTIONS: &[&str] = &["--json"];
const CANCEL_OPTIONS: &[&str] = &["--by", "--safe"];

fn write_out(bytes: &[u8]) -> Result<()> {
    std::io::stdout()
        .write_all(bytes)
        .map_err(|e| Error::Failed(e.to_string()))
}

fn open_store() -> Result<Store> {
    let dir = std::env::var("HS_JOBS_DIR")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| DEFAULT_DIR.to_string());
    let mut store = Store::new(dir);
    // job-record.py reads the knob before anything else, and a bad value ends every command
    let raw = std::env::var("HS_JOB_RATE").unwrap_or_else(|_| "1".to_string());
    store.rate = raw
        .trim()
        .parse()
        .map_err(|_| Error::Failed(format!("invalid HS_JOB_RATE: {raw}")))?;
    Ok(store)
}

pub(crate) fn run(args: &[String]) -> Result<u8> {
    // hs_job_record asks this before it trusts the binary: an older build answers "unknown subcommand" (exit 1) instead
    if args == ["--probe"] {
        return Ok(output::exit_with(output::line("job-record"), EXIT_OK));
    }
    let store = open_store()?;
    let (command, words) = args.split_first().ok_or_else(bad)?;
    let done = match command.as_str() {
        "reconcile" => return reconcile(&store, words),
        "cancelled" => return cancelled(&store, words),
        "new" => new_record(&store, words),
        "wait" => wait(&store, words),
        "error" => set_error(&store, words),
        "result" => set_result(&store, words),
        "cancel" => cancel(&store, words),
        "get" => get(&store, words),
        "find-unit" => find_unit(&store, words),
        other => change_record(&store, other, words),
    };
    done.map(|()| EXIT_OK)
}

/// The changes to a record that take positionals only. An unknown command ends here, as bad arguments whatever its words are.
fn change_record(store: &Store, command: &str, words: &[String]) -> Result<()> {
    let arguments = Arguments::parse(words, &[])?;
    match command {
        "run" => {
            let [id] = arguments.positionals()?;
            store.run(id)
        }
        "resume" => {
            let [id] = arguments.positionals()?;
            store.resume(id)
        }
        "step" => {
            let [id, number, of, text] = arguments.positionals()?;
            store.step(id, whole_number(number)?, whole_number(of)?, text)
        }
        "progress" => {
            let [id, done, total, unit] = arguments.positionals()?;
            store.progress(id, whole_number(done)?, whole_number(total)?, unit)
        }
        "key" => {
            let [id, key] = arguments.positionals()?;
            store.set_key(id, key)
        }
        "skip" => {
            let [id, message] = arguments.positionals()?;
            store.skip(id, message)
        }
        "finish" => {
            let [id, code] = arguments.positionals()?;
            store.finish(id, whole_number(code)?)
        }
        "uncancel" => {
            let [id] = arguments.positionals()?;
            store.uncancel(id)
        }
        _ => Err(bad()),
    }
}

fn get(store: &Store, words: &[String]) -> Result<()> {
    let arguments = Arguments::parse(words, &[])?;
    let [id] = arguments.positionals()?;
    write_out(&store.get(id)?)
}

fn find_unit(store: &Store, words: &[String]) -> Result<()> {
    let arguments = Arguments::parse(words, &[])?;
    let [unit] = arguments.positionals()?;
    let id = store.find_unit(unit)?;
    write_out(format!("{id}\n").as_bytes())
}

fn new_record(store: &Store, words: &[String]) -> Result<()> {
    let arguments = Arguments::parse(words, NEW_OPTIONS)?;
    let [] = arguments.positionals()?;
    let id = store.new_record(&NewJob {
        slug: arguments.required("--slug")?,
        description: arguments.required("--desc")?,
        unit: arguments.option("--unit").unwrap_or(""),
        source: arguments.option("--source").unwrap_or("cli"),
        initiator: arguments.option("--initiator").unwrap_or(""),
        parent: arguments.option("--parent").unwrap_or(""),
        kind: arguments.option("--kind").unwrap_or(""),
    })?;
    write_out(format!("{id}\n").as_bytes())
}

fn wait(store: &Store, words: &[String]) -> Result<()> {
    let arguments = Arguments::parse(words, WAIT_OPTIONS)?;
    let [id] = arguments.positionals()?;
    let question = Question {
        seq: whole_number(arguments.required("--seq")?)?,
        key: arguments.required("--key")?,
        label: arguments.required("--label")?,
        kind: arguments.required("--kind")?,
        default: arguments.option("--default").unwrap_or(""),
        pattern: arguments.option("--pattern").unwrap_or(""),
        choices: arguments.option("--choices").unwrap_or(""),
        error: arguments.option("--error").unwrap_or(""),
        attempt: whole_number(arguments.option("--attempt").unwrap_or("1"))?,
    };
    store.wait(id, &question)
}

fn set_error(store: &Store, words: &[String]) -> Result<()> {
    let arguments = Arguments::parse(words, ERROR_OPTIONS)?;
    let [id] = arguments.positionals()?;
    store.set_error(
        id,
        arguments.required("--category")?,
        arguments.option("--message").unwrap_or(""),
        arguments.option("--code"),
    )
}

fn set_result(store: &Store, words: &[String]) -> Result<()> {
    let arguments = Arguments::parse(words, RESULT_OPTIONS)?;
    let [id] = arguments.positionals()?;
    store.set_result(id, arguments.required("--json")?)
}

fn cancel(store: &Store, words: &[String]) -> Result<()> {
    let arguments = Arguments::parse(words, CANCEL_OPTIONS)?;
    let [id] = arguments.positionals()?;
    let safe = match arguments.option("--safe") {
        Some("yes") => true,
        Some("no") => false,
        _ => return Err(bad()),
    };
    store.cancel(id, arguments.option("--by").unwrap_or(""), safe)
}

/// One line per record marked interrupted on stdout, one per failure on stderr; exit 1 when there was a failure.
fn reconcile(store: &Store, words: &[String]) -> Result<u8> {
    let arguments = Arguments::parse(words, &[])?;
    let [] = arguments.positionals()?;
    let report = store.reconcile(&RealSystem);
    for (id, slug, description) in &report.lines {
        write_out(format!("{id}\t{slug}\t{description}\n").as_bytes())?;
    }
    let written = report
        .errors
        .iter()
        .try_for_each(|error| output::error_line(format_args!("hobnix: {error}")));
    let code = if report.errors.is_empty() {
        EXIT_OK
    } else {
        EXIT_REFUSED
    };
    Ok(output::exit_with(written, code))
}

/// Exit 0 when the job is cancelled, else 1, without a line.
fn cancelled(store: &Store, words: &[String]) -> Result<u8> {
    let arguments = Arguments::parse(words, &[])?;
    let [id] = arguments.positionals()?;
    Ok(if store.is_cancelled(id)? {
        EXIT_OK
    } else {
        EXIT_REFUSED
    })
}
