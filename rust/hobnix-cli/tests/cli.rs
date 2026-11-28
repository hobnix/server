use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

fn command(args: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_hobnix"));
    command.args(args).env_remove("HOBNIX_LOG");
    command
}

fn hobnix(args: &[&str]) -> io::Result<Output> {
    command(args).output()
}

#[test]
fn no_args_prints_version() -> io::Result<()> {
    let o = hobnix(&[])?;
    assert_eq!(o.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&o.stdout).starts_with("hobnix "));
    Ok(())
}

#[test]
fn unknown_subcommand_is_refused() -> io::Result<()> {
    let o = hobnix(&["frobnicate"])?;
    assert_eq!(o.status.code(), Some(1));
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(err.starts_with("hobnix: "));
    assert!(err.contains("unknown subcommand: frobnicate"));
    assert!(o.stdout.is_empty());
    Ok(())
}

fn hobnix_env(args: &[&str], env: &[(&str, &str)], unset: &[&str]) -> io::Result<Output> {
    let mut c = command(args);
    for (k, v) in env {
        c.env(k, v);
    }
    for k in unset {
        c.env_remove(k);
    }
    c.output()
}

fn refused_text(reason: &str, code: &str) -> String {
    format!("status\trefused\nreason\t{reason}\ncode\t{code}\n")
}

#[test]
fn secrets_without_verb_prints_usage() -> io::Result<()> {
    let o = hobnix(&["secrets"])?;
    assert_eq!(o.status.code(), Some(1));
    assert!(o.stdout.is_empty());
    assert_eq!(
        String::from_utf8_lossy(&o.stderr),
        "usage: vault-change.sh plan|start header-backup|move [<name>...]|close|secrets-fix\n"
    );
    Ok(())
}

#[test]
fn secrets_refusals_are_lines_on_stdout() -> io::Result<()> {
    let cases = [
        (
            vec!["secrets", "plan", "init"],
            "unknown action (header-backup, move, close or secrets-fix)",
            "action.unknown",
        ),
        (
            vec!["secrets", "plan", "close", "--bogus"],
            "unknown option --bogus",
            "option.unknown",
        ),
        (
            vec!["secrets", "plan", "move", "a b"],
            "'a b' is not a name of a secret",
            "vault.name-invalid",
        ),
    ];
    for (args, reason, code) in cases {
        let o = hobnix(&args)?;
        assert_eq!(o.status.code(), Some(1), "{args:?}");
        assert_eq!(
            String::from_utf8_lossy(&o.stdout),
            refused_text(reason, code)
        );
    }
    Ok(())
}

#[test]
fn secrets_fix_plan() -> io::Result<()> {
    let o = hobnix_env(
        &["secrets", "plan", "secrets-fix"],
        &[("HS_SCRIPTS", "/nonexistent")],
        &[],
    )?;
    assert_eq!(o.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "status\tok\nheading\tset root-only permissions on the secrets\nstep\tmake the files that hold secrets readable by root only (the content of the vault is not touched)\ncommand\ths secrets fix\nlong\tno\n"
    );
    Ok(())
}

#[test]
fn secrets_without_hs_scripts_is_exit_2() -> io::Result<()> {
    let o = hobnix_env(&["secrets", "plan", "secrets-fix"], &[], &["HS_SCRIPTS"])?;
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).starts_with("hobnix: "));
    assert!(o.stdout.is_empty());
    Ok(())
}

fn job_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("hobnix-cli-jobs-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

fn job(dir: &Path, args: &[&str]) -> io::Result<Output> {
    command(&["job-record"])
        .args(args)
        .env("HS_JOBS_DIR", dir)
        .output()
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[test]
fn job_record_life_of_a_job() -> io::Result<()> {
    let dir = job_dir("life");
    let o = job(
        &dir,
        &[
            "new",
            "--slug",
            "pool sync",
            "--desc",
            "hs pool sync",
            "--unit",
            "hs-job-x-1",
            "--initiator",
            "alice",
        ],
    )?;
    assert_eq!(o.status.code(), Some(0));
    let id = text(&o.stdout).trim().to_string();
    assert!(id.contains("-pool-sync-"), "{id}");
    assert_eq!(job(&dir, &["run", &id])?.status.code(), Some(0));
    assert_eq!(
        job(&dir, &["step", &id, "2", "2", "last"])?.status.code(),
        Some(0)
    );
    assert_eq!(job(&dir, &["cancelled", &id])?.status.code(), Some(1));
    let o = job(&dir, &["find-unit", "hs-job-x-1.service"])?;
    assert_eq!(text(&o.stdout), format!("{id}\n"));
    assert_eq!(job(&dir, &["finish", &id, "0"])?.status.code(), Some(0));
    let o = job(&dir, &["get", &id])?;
    let rec = text(&o.stdout);
    assert!(rec.starts_with("{\n  \"id\": "), "{rec}");
    assert!(rec.contains("\"state\": \"ok\""));
    assert!(
        rec.contains("\"step\": {\n    \"n\": 2,\n    \"of\": 2,\n    \"text\": \"last\"\n  }")
    );
    let o = job(&dir, &["cancel", &id, "--by", "bob", "--safe", "yes"])?;
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(text(&o.stderr), "hobnix: job already finished\n");
    let _ = std::fs::remove_dir_all(&dir);
    Ok(())
}

#[test]
fn job_record_failures_are_one_line_and_exit_1() -> io::Result<()> {
    let dir = job_dir("fail");
    for (args, line) in [
        (vec!["get", "nope"], "hobnix: bad job id\n"),
        (vec!["bogus"], "hobnix: bad arguments\n"),
        (vec!["new", "--slug", "x"], "hobnix: bad arguments\n"),
        (
            vec!["step", "20240101-120000-a-abcd", "x", "1", "t"],
            "hobnix: bad arguments\n",
        ),
        (
            vec!["cancel", "20240101-120000-a-abcd", "--safe", "maybe"],
            "hobnix: bad arguments\n",
        ),
        (
            vec!["new", "--slug", "x", "--desc", "d", "--source", "bogus"],
            "hobnix: bad source: bogus\n",
        ),
        (
            vec!["find-unit", "none"],
            "hobnix: no running job record for none\n",
        ),
    ] {
        let o = job(&dir, &args)?;
        assert_eq!(o.status.code(), Some(1), "{args:?}");
        assert_eq!(text(&o.stderr), line, "{args:?}");
        assert!(o.stdout.is_empty(), "{args:?}");
    }
    let _ = std::fs::remove_dir_all(&dir);
    Ok(())
}

#[test]
fn job_record_probe_answers_its_name() -> io::Result<()> {
    let o = hobnix(&["job-record", "--probe"])?;
    assert_eq!(o.status.code(), Some(0));
    assert_eq!(text(&o.stdout), "job-record\n");
    assert!(o.stderr.is_empty());
    Ok(())
}

const ID: &str = "20240101-120000-a-abcd";

/// The words after `job-record` that the argument reader or the command refuses before it looks for a record.
const BAD_JOB_RECORD_WORDS: &[&[&str]] = &[
    &[],
    &["--probe", "x"],
    &["new"],
    &["new", "--desc", "d"],
    &["new", "--slug", "s", "--desc", "d", "extra"],
    &["new", "--slug", "s", "--desc"],
    &["run"],
    &["run", ID, ID],
    &["run", "--x", ID],
    &["wait", ID],
    &[
        "wait", ID, "--seq", "x", "--key", "k", "--label", "l", "--kind", "text",
    ],
    &["wait", ID, "--seq", "1", "--label", "l", "--kind", "text"],
    &["wait", ID, "--seq", "1", "--key", "k", "--kind", "text"],
    &["wait", ID, "--seq", "1", "--key", "k", "--label", "l"],
    &[
        "wait",
        ID,
        "--seq",
        "1",
        "--key",
        "k",
        "--label",
        "l",
        "--kind",
        "text",
        "--attempt",
        "x",
    ],
    &["wait", ID, "--k", "k"],
    &["resume"],
    &["step", ID, "1", "2"],
    &["step", ID, "1", "x", "t"],
    &["progress", ID, "x", "2", "u"],
    &["progress", ID, "1", "x", "u"],
    &["progress", ID, "1", "2"],
    &["key", ID],
    &["error", ID],
    &["error", "--category", "c"],
    &["result", ID],
    &["result", "--json", "{}"],
    &["skip", ID],
    &["finish", ID],
    &["finish", ID, "x"],
    &["get"],
    &["reconcile", "x"],
    &["find-unit"],
    &["cancel", ID],
    &["cancel", "--safe", "yes"],
    &["uncancel"],
    &["cancelled"],
    &["bogus", "--x"],
    &["bogus", ID],
    &["--help"],
];

#[test]
fn job_record_refuses_wrong_words_for_every_command() -> io::Result<()> {
    let dir = job_dir("words");
    for args in BAD_JOB_RECORD_WORDS {
        let o = job(&dir, args)?;
        assert_eq!(o.status.code(), Some(1), "{args:?}");
        assert_eq!(text(&o.stderr), "hobnix: bad arguments\n", "{args:?}");
        assert!(o.stdout.is_empty(), "{args:?}");
    }
    let _ = std::fs::remove_dir_all(&dir);
    Ok(())
}

#[test]
fn job_record_reads_the_rate_before_the_command() -> io::Result<()> {
    let o = hobnix_env(&["job-record"], &[("HS_JOB_RATE", "often")], &[])?;
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(text(&o.stderr), "hobnix: invalid HS_JOB_RATE: often\n");
    Ok(())
}

#[test]
fn pair_refuses_wrong_words() -> io::Result<()> {
    let usage = "hobnix: usage: hobnix pair make|cancel|check|request|open|push\n";
    let make = "hobnix: usage: pair make <offer|receive> <share|-> <server|-> <minutes>\n";
    let table: &[(&[&str], &str)] = &[
        (&["pair"], usage),
        (&["pair", "bogus"], usage),
        (&["pair", "make"], make),
        (&["pair", "make", "offer", "s", "-"], make),
        (&["pair", "make", "offer", "s", "-", "1", "x"], make),
        (
            &["pair", "make", "gift", "s", "-", "x"],
            "hobnix: the kind is offer or receive\n",
        ),
        (
            &["pair", "make", "offer", "s", "-", "x"],
            "hobnix: minutes is a number\n",
        ),
        (
            &["remote-codes", "x"],
            "hobnix: hs sys remote codes takes no arguments\n",
        ),
        (
            &["remote-claim", "x"],
            "hobnix: usage: --source <address>\n",
        ),
        (
            &["remote-accept", "--source", ""],
            "hobnix: usage: --source <address>\n",
        ),
    ];
    for (args, line) in table {
        let o = hobnix(args)?;
        assert_eq!(o.status.code(), Some(1), "{args:?}");
        assert_eq!(text(&o.stderr), *line, "{args:?}");
        assert!(o.stdout.is_empty(), "{args:?}");
    }
    Ok(())
}

fn hobnix_stdin(args: &[&str], input: &str) -> io::Result<Output> {
    let mut child = command(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("no standard input"))?
        .write_all(input.as_bytes())?;
    child.wait_with_output()
}

#[test]
fn pair_check_prints_the_code_in_groups_and_the_part_after_the_at() -> io::Result<()> {
    for (typed, line) in [
        ("abcd-efgh-jklm-npqr\n", "ABCD-EFGH-JKLM-NPQR\t-\n"),
        ("ABCDEFGHJKLMNPQR@host\n", "ABCD-EFGH-JKLM-NPQR\thost\n"),
        ("ABCDEFGHJKLMNPQR@\n", "ABCD-EFGH-JKLM-NPQR\t-\n"),
    ] {
        let o = hobnix_stdin(&["pair", "check"], typed)?;
        assert_eq!(o.status.code(), Some(0), "{typed:?}");
        assert_eq!(text(&o.stdout), line, "{typed:?}");
    }
    Ok(())
}

#[test]
fn pair_refuses_what_it_reads_from_standard_input() -> io::Result<()> {
    let not_a_code = "hobnix: that is not a code (16 letters and digits)\n";
    for (word, typed, line) in [
        ("check", "nope\n", not_a_code),
        (
            "request",
            "nope\n",
            "hobnix: need key<TAB>value lines on standard input\n",
        ),
        ("open", "code\tnope\n", not_a_code),
        (
            "open",
            "code\tABCDEFGHJKLMNPQR\n",
            "hobnix: the answer does not open: wrong code, or not the server that made it\n",
        ),
        (
            "push",
            "code\tABCDEFGHJKLMNPQR\n",
            "hobnix: the inner document is not valid\n",
        ),
    ] {
        let o = hobnix_stdin(&["pair", word], typed)?;
        assert_eq!(o.status.code(), Some(1), "{word} {typed:?}");
        assert_eq!(text(&o.stderr), line, "{word} {typed:?}");
        assert!(o.stdout.is_empty(), "{word} {typed:?}");
    }
    Ok(())
}

/// A pipe nobody reads: every write to it fails.
fn closed_pipe() -> io::Result<Stdio> {
    let (reader, writer) = io::pipe()?;
    drop(reader);
    Ok(writer.into())
}

#[test]
fn a_lost_standard_output_ends_with_the_exit_code_of_println() -> io::Result<()> {
    for args in [&["--version"][..], &["job-record", "--probe"]] {
        let o = command(args).stdout(closed_pipe()?).output()?;
        assert_eq!(o.status.code(), Some(101), "{args:?}");
        let said = text(&o.stderr);
        assert!(
            said.contains("failed printing to stdout: Broken pipe"),
            "{args:?}: {said}"
        );
    }
    Ok(())
}

#[test]
fn a_lost_standard_error_ends_with_the_exit_code_of_eprintln() -> io::Result<()> {
    for (args, level) in [
        (&["frobnicate"][..], "info"),
        (&["secrets"], "info"),
        (&["event-emit"], "info"),
        // the debug line comes first: the command does not run
        (&["--version"], "debug"),
    ] {
        let o = command(args)
            .env("HOBNIX_LOG", level)
            .stderr(closed_pipe()?)
            .output()?;
        assert_eq!(o.status.code(), Some(101), "{args:?} {level}");
        assert!(o.stdout.is_empty(), "{args:?} {level}");
    }
    Ok(())
}
