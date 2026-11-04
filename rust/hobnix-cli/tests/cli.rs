use std::process::Command;

fn hobnix(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_hobnix"))
        .args(args)
        .env_remove("HOBNIX_LOG")
        .output()
        .unwrap()
}

#[test]
fn no_args_prints_version() {
    let o = hobnix(&[]);
    assert_eq!(o.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&o.stdout).starts_with("hobnix "));
}

#[test]
fn unknown_subcommand_is_refused() {
    let o = hobnix(&["frobnicate"]);
    assert_eq!(o.status.code(), Some(1));
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(err.starts_with("hobnix: "));
    assert!(err.contains("unknown subcommand: frobnicate"));
    assert!(o.stdout.is_empty());
}

fn hobnix_env(args: &[&str], env: &[(&str, &str)], unset: &[&str]) -> std::process::Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_hobnix"));
    c.args(args).env_remove("HOBNIX_LOG");
    for (k, v) in env {
        c.env(k, v);
    }
    for k in unset {
        c.env_remove(k);
    }
    c.output().unwrap()
}

fn refused_text(reason: &str) -> String {
    format!("status\trefused\nreason\t{reason}\n")
}

#[test]
fn secrets_without_verb_prints_usage() {
    let o = hobnix(&["secrets"]);
    assert_eq!(o.status.code(), Some(1));
    assert!(o.stdout.is_empty());
    assert_eq!(
        String::from_utf8_lossy(&o.stderr),
        "usage: vault-change.sh plan|start header-backup|move [<name>...]|close|secrets-fix\n"
    );
}

#[test]
fn secrets_refusals_are_lines_on_stdout() {
    let cases = [
        (
            vec!["secrets", "plan", "init"],
            "unknown action (header-backup, move, close or secrets-fix)",
        ),
        (
            vec!["secrets", "plan", "close", "--bogus"],
            "unknown option --bogus",
        ),
        (
            vec!["secrets", "plan", "move", "a b"],
            "'a b' is not a name of a secret",
        ),
    ];
    for (args, reason) in cases {
        let o = hobnix(&args);
        assert_eq!(o.status.code(), Some(1), "{args:?}");
        assert_eq!(String::from_utf8_lossy(&o.stdout), refused_text(reason));
    }
}

#[test]
fn secrets_fix_plan() {
    let o = hobnix_env(
        &["secrets", "plan", "secrets-fix"],
        &[("HS_SCRIPTS", "/nonexistent")],
        &[],
    );
    assert_eq!(o.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&o.stdout),
        "status\tok\nheading\tset root-only permissions on the secrets\nstep\tmake the files that hold secrets readable by root only (the content of the vault is not touched)\ncommand\ths secrets fix\nlong\tno\n"
    );
}

#[test]
fn secrets_without_hs_scripts_is_exit_2() {
    let o = hobnix_env(&["secrets", "plan", "secrets-fix"], &[], &["HS_SCRIPTS"]);
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).starts_with("hobnix: "));
    assert!(o.stdout.is_empty());
}

fn job_dir(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("hobnix-cli-jobs-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

fn job(dir: &std::path::Path, args: &[&str]) -> std::process::Output {
    let mut a = vec!["job-record"];
    a.extend_from_slice(args);
    hobnix_env(&a, &[("HS_JOBS_DIR", dir.to_str().unwrap())], &[])
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[test]
fn job_record_life_of_a_job() {
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
    );
    assert_eq!(o.status.code(), Some(0));
    let id = text(&o.stdout).trim().to_string();
    assert!(id.contains("-pool-sync-"), "{id}");
    assert_eq!(job(&dir, &["run", &id]).status.code(), Some(0));
    assert_eq!(
        job(&dir, &["step", &id, "2", "2", "last"]).status.code(),
        Some(0)
    );
    assert_eq!(job(&dir, &["cancelled", &id]).status.code(), Some(1));
    let o = job(&dir, &["find-unit", "hs-job-x-1.service"]);
    assert_eq!(text(&o.stdout), format!("{id}\n"));
    assert_eq!(job(&dir, &["finish", &id, "0"]).status.code(), Some(0));
    let o = job(&dir, &["get", &id]);
    let rec = text(&o.stdout);
    assert!(rec.starts_with("{\n  \"id\": "), "{rec}");
    assert!(rec.contains("\"state\": \"ok\""));
    assert!(rec.contains("\"step\": {\n    \"n\": 2,\n    \"of\": 2,\n    \"text\": \"last\"\n  }"));
    let o = job(&dir, &["cancel", &id, "--by", "bob", "--safe", "yes"]);
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(text(&o.stderr), "hobnix: job already finished\n");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn job_record_failures_are_one_line_and_exit_1() {
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
        let o = job(&dir, &args);
        assert_eq!(o.status.code(), Some(1), "{args:?}");
        assert_eq!(text(&o.stderr), line, "{args:?}");
        assert!(o.stdout.is_empty(), "{args:?}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}
