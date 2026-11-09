//! `hobnix job-record <words>`: the words and flags of scripts/job-record.py, answered by hobnix-core's job store.
//!
//! Exit codes follow job-record.py, not the 0/1/2 scheme of the other commands: every failure is one stderr line
//! `hobnix: <msg>` and exit 1 (`cancelled` exits 1 without a line when the job is not cancelled). The scripts that call it
//! only ever test for zero.

use hobnix_core::jobs::{Question, RealSystem, Store};
use hobnix_core::{Error, Result, EXIT_OK, EXIT_REFUSED};
use std::io::Write;

const BAD_ARGS: &str = "bad arguments";
const DEFAULT_DIR: &str = "/var/lib/hs/jobs";

fn bad() -> Error {
    Error::Failed(BAD_ARGS.to_string())
}

/// Python's int(): surrounding white space, a sign, digits with single underscores between them.
fn parse_int(s: &str) -> Result<i64> {
    let t = s.trim();
    let digits = t.strip_prefix(['+', '-']).unwrap_or(t);
    let ok = !digits.is_empty()
        && !digits.starts_with('_')
        && !digits.ends_with('_')
        && !digits.contains("__")
        && digits.bytes().all(|b| b.is_ascii_digit() || b == b'_');
    if !ok {
        return Err(bad());
    }
    t.replace('_', "").parse().map_err(|_| bad())
}

/// argparse's "looks like a negative number" (the parser has no option that does).
fn negative_number(s: &str) -> bool {
    let Some(r) = s.strip_prefix('-') else {
        return false;
    };
    if !r.is_empty() && r.bytes().all(|b| b.is_ascii_digit()) {
        return true;
    }
    match r.split_once('.') {
        Some((a, b)) => {
            a.bytes().all(|c| c.is_ascii_digit())
                && !b.is_empty()
                && b.bytes().all(|c| c.is_ascii_digit())
        }
        None => false,
    }
}

/// argparse's test for "this is an option, not a value".
fn option_like(s: &str) -> bool {
    s.len() > 1 && s.starts_with('-') && !negative_number(s) && !s.contains(' ')
}

#[derive(Default)]
struct Parsed {
    pos: Vec<String>,
    opts: Vec<(&'static str, String)>,
}

impl Parsed {
    fn opt(&self, name: &str) -> Option<&str> {
        self.opts
            .iter()
            .rev()
            .find(|(n, _)| *n == name)
            .map(|(_, v)| v.as_str())
    }
}

/// Positionals and `--long value` / `--long=value` options (unique prefixes allowed, like argparse).
/// `-h` and `--help` are not answered (job-record.py prints its usage and exits 0): they are bad arguments here.
fn parse(args: &[String], longs: &[&'static str]) -> Result<Parsed> {
    let mut p = Parsed::default();
    let mut i = 0;
    let mut only_pos = false;
    while i < args.len() {
        let a = &args[i];
        i += 1;
        if only_pos || !a.starts_with('-') || a == "-" {
            p.pos.push(a.clone());
        } else if a == "--" {
            only_pos = true;
        } else if let Some(body) = a.strip_prefix("--") {
            let (name, explicit) = match body.split_once('=') {
                Some((n, v)) => (n, Some(v.to_string())),
                None => (body, None),
            };
            let exact = longs.iter().find(|l| l[2..] == *name);
            let hits: Vec<&&'static str> =
                longs.iter().filter(|l| l[2..].starts_with(name)).collect();
            let found = match (exact, hits.as_slice()) {
                (Some(l), _) => Some(*l),
                (None, [one]) => Some(**one),
                _ => None,
            };
            let Some(opt) = found else {
                if a.contains(' ') {
                    p.pos.push(a.clone());
                    continue;
                }
                return Err(bad());
            };
            let value = match explicit {
                Some(v) => v,
                None => {
                    let v = args.get(i).ok_or_else(bad)?;
                    if option_like(v) {
                        return Err(bad());
                    }
                    i += 1;
                    v.clone()
                }
            };
            p.opts.push((opt, value));
        } else if negative_number(a) || a.contains(' ') {
            p.pos.push(a.clone());
        } else {
            return Err(bad());
        }
    }
    Ok(p)
}

fn exact<const N: usize>(p: &Parsed) -> Result<&[String; N]> {
    p.pos.as_slice().try_into().map_err(|_| bad())
}

fn out(bytes: &[u8]) -> Result<()> {
    std::io::stdout()
        .write_all(bytes)
        .map_err(|e| Error::Failed(e.to_string()))
}

fn store() -> Result<Store> {
    let dir = std::env::var("HS_JOBS_DIR")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| DEFAULT_DIR.to_string());
    let mut s = Store::new(dir);
    // job-record.py reads the knob before anything else, and a bad value ends every command
    let raw = std::env::var("HS_JOB_RATE").unwrap_or_else(|_| "1".to_string());
    s.rate = raw
        .trim()
        .parse()
        .map_err(|_| Error::Failed(format!("invalid HS_JOB_RATE: {raw}")))?;
    Ok(s)
}

pub fn run(args: &[String]) -> Result<u8> {
    // hs_job_record asks this before it trusts the binary: an older build answers "unknown subcommand" (exit 1) instead
    if args == ["--probe"] {
        println!("job-record");
        return Ok(0);
    }
    let store = store()?;
    let (cmd, rest) = args.split_first().ok_or_else(bad)?;
    match cmd.as_str() {
        "new" => {
            let p = parse(
                rest,
                &[
                    "--slug",
                    "--desc",
                    "--unit",
                    "--source",
                    "--initiator",
                    "--parent",
                    "--kind",
                ],
            )?;
            exact::<0>(&p)?;
            let slug = p.opt("--slug").ok_or_else(bad)?;
            let desc = p.opt("--desc").ok_or_else(bad)?;
            let id = store.new_record(
                slug,
                desc,
                p.opt("--unit").unwrap_or(""),
                p.opt("--source").unwrap_or("cli"),
                p.opt("--initiator").unwrap_or(""),
                p.opt("--parent").unwrap_or(""),
                p.opt("--kind").unwrap_or(""),
            )?;
            out(format!("{id}\n").as_bytes())?;
        }
        "run" => {
            let p = parse(rest, &[])?;
            store.run(&exact::<1>(&p)?[0])?;
        }
        "wait" => {
            let p = parse(
                rest,
                &[
                    "--seq",
                    "--key",
                    "--label",
                    "--kind",
                    "--default",
                    "--pattern",
                    "--choices",
                    "--error",
                    "--attempt",
                ],
            )?;
            let id = &exact::<1>(&p)?[0];
            let q = Question {
                seq: parse_int(p.opt("--seq").ok_or_else(bad)?)?,
                key: p.opt("--key").ok_or_else(bad)?,
                label: p.opt("--label").ok_or_else(bad)?,
                kind: p.opt("--kind").ok_or_else(bad)?,
                default: p.opt("--default").unwrap_or(""),
                pattern: p.opt("--pattern").unwrap_or(""),
                choices: p.opt("--choices").unwrap_or(""),
                error: p.opt("--error").unwrap_or(""),
                attempt: parse_int(p.opt("--attempt").unwrap_or("1"))?,
            };
            store.wait(id, &q)?;
        }
        "resume" => {
            let p = parse(rest, &[])?;
            store.resume(&exact::<1>(&p)?[0])?;
        }
        "step" => {
            let p = parse(rest, &[])?;
            let [id, n, of, text] = exact::<4>(&p)?;
            store.step(id, parse_int(n)?, parse_int(of)?, text)?;
        }
        "progress" => {
            let p = parse(rest, &[])?;
            let [id, done, total, unit] = exact::<4>(&p)?;
            store.progress(id, parse_int(done)?, parse_int(total)?, unit)?;
        }
        "finish" => {
            let p = parse(rest, &[])?;
            let [id, code] = exact::<2>(&p)?;
            store.finish(id, parse_int(code)?)?;
        }
        "get" => {
            let p = parse(rest, &[])?;
            out(&store.get(&exact::<1>(&p)?[0])?)?;
        }
        "reconcile" => {
            let p = parse(rest, &[])?;
            exact::<0>(&p)?;
            let r = store.reconcile(&RealSystem);
            for (id, slug, desc) in &r.lines {
                out(format!("{id}\t{slug}\t{desc}\n").as_bytes())?;
            }
            for e in &r.errors {
                eprintln!("hobnix: {e}");
            }
            if !r.errors.is_empty() {
                return Ok(EXIT_REFUSED);
            }
        }
        "find-unit" => {
            let p = parse(rest, &[])?;
            let id = store.find_unit(&exact::<1>(&p)?[0])?;
            out(format!("{id}\n").as_bytes())?;
        }
        "cancel" => {
            let p = parse(rest, &["--by", "--safe"])?;
            let id = &exact::<1>(&p)?[0];
            let safe = match p.opt("--safe") {
                Some("yes") => true,
                Some("no") => false,
                _ => return Err(bad()),
            };
            store.cancel(id, p.opt("--by").unwrap_or(""), safe)?;
        }
        "uncancel" => {
            let p = parse(rest, &[])?;
            store.uncancel(&exact::<1>(&p)?[0])?;
        }
        "cancelled" => {
            let p = parse(rest, &[])?;
            if !store.is_cancelled(&exact::<1>(&p)?[0])? {
                return Ok(EXIT_REFUSED);
            }
        }
        _ => return Err(bad()),
    }
    Ok(EXIT_OK)
}
