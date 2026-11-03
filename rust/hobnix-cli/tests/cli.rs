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
