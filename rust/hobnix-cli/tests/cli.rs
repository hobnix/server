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
