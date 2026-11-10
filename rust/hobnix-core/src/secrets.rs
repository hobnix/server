//! hs sys secrets plan|start: the vault and the secrets (the rows scripts/vault-change.sh answered). No output, no argv.

use crate::{Error, Result};
use std::process::{Command, Stdio};

/// Runs the job library, then `hs_job <slug> <description> -- <argv...>`; prints the unit name.
const JOB_WRAPPER: &str = r#"set -uo pipefail; . "$1" || exit 1; shift; hs_job "$@""#;

/// The name of a secret: `^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecretName(String);

impl SecretName {
    pub fn parse(s: &str) -> Option<Self> {
        let bytes = s.as_bytes();
        let first_ok = bytes.first().is_some_and(u8::is_ascii_alphanumeric);
        let rest_ok = bytes
            .iter()
            .skip(1)
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
        if (1..=61).contains(&bytes.len()) && first_ok && rest_ok {
            Some(SecretName(s.to_string()))
        } else {
            None
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// What the vault page can ask for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    HeaderBackup,
    Move(Vec<SecretName>),
    Close,
    SecretsFix,
}

impl Action {
    /// The action named by a word; `Move` comes with no names.
    pub fn parse(word: &str) -> Option<Action> {
        match word {
            "header-backup" => Some(Action::HeaderBackup),
            "move" => Some(Action::Move(Vec::new())),
            "close" => Some(Action::Close),
            "secrets-fix" => Some(Action::SecretsFix),
            _ => None,
        }
    }

    pub fn word(&self) -> &'static str {
        match self {
            Action::HeaderBackup => "header-backup",
            Action::Move(_) => "move",
            Action::Close => "close",
            Action::SecretsFix => "secrets-fix",
        }
    }
}

/// State of the vault as `vault.sh usage` reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VaultState {
    Open,
    Closed,
    Absent,
}

impl VaultState {
    /// Reads the first `state<TAB>value` line of the usage output.
    pub fn from_usage(stdout: &str) -> VaultState {
        let line = stdout
            .split('\n')
            .find(|l| l.split('\t').next() == Some("state"));
        match line.and_then(|l| l.split('\t').nth(1)).unwrap_or("") {
            "open" => VaultState::Open,
            "closed" => VaultState::Closed,
            _ => VaultState::Absent,
        }
    }
}

/// Where the scripts are (HS_SCRIPTS, as `hs` exports it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Paths {
    pub vault: String,
    pub secrets: String,
    pub job_lib: String,
}

impl Paths {
    pub fn from_env() -> Result<Paths> {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let scripts = var("HS_SCRIPTS")
            .ok_or_else(|| Error::Missing("HS_SCRIPTS is not set (run it through hs)".into()))?;
        Ok(Paths {
            vault: var("HS_VAULT").unwrap_or_else(|| format!("{scripts}/vault.sh")),
            secrets: var("HS_SECRETS").unwrap_or_else(|| format!("{scripts}/secrets.sh")),
            job_lib: format!("{scripts}/lib/job.sh"),
        })
    }
}

/// A background job: what `hs_job` gets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JobSpec {
    pub slug: String,
    pub description: String,
    pub argv: Vec<String>,
}

/// What the page shows before the user confirms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub heading: &'static str,
    pub steps: Vec<String>,
    pub dangers: Vec<&'static str>,
    pub note: Option<&'static str>,
    pub command: String,
    pub confirm_name: Option<&'static str>,
    pub long: bool,
    pub job: JobSpec,
}

/// The outside world: the vault script and the job runner.
pub trait Host {
    /// stdout of `bash <vault> usage` (stdin /dev/null, stderr dropped); "" when it cannot run
    fn vault_usage(&self, vault: &str) -> String;
    /// starts the job through hs_job of `job_lib`, returns the unit name
    fn start_job(&self, job_lib: &str, job: &JobSpec) -> Result<String>;
}

/// The real host: child processes.
pub struct SystemHost {
    caller: String,
}

impl SystemHost {
    pub fn from_env() -> SystemHost {
        let caller = std::env::var("HS_CALLER")
            .ok()
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "ui".to_string());
        SystemHost { caller }
    }

    fn command(&self, program: &str) -> Command {
        let mut c = Command::new(program);
        c.env("HS_PLAIN", "1")
            .env("HS_LANG", "en")
            .env("HS_CALLER", &self.caller)
            .env_remove("HS_GUIDED_TTY");
        c
    }
}

impl Host for SystemHost {
    fn vault_usage(&self, vault: &str) -> String {
        match self
            .command("bash")
            .arg(vault)
            .arg("usage")
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
        {
            Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
            Err(_) => String::new(),
        }
    }

    fn start_job(&self, job_lib: &str, job: &JobSpec) -> Result<String> {
        let failed = || Error::Failed("the job could not be started".into());
        let o = self
            .command("bash")
            .arg("-c")
            .arg(JOB_WRAPPER)
            .arg("hobnix-job")
            .arg(job_lib)
            .arg(&job.slug)
            .arg(&job.description)
            .arg("--")
            .args(&job.argv)
            .stdin(Stdio::inherit())
            .stderr(Stdio::inherit())
            .stdout(Stdio::piped())
            .output()
            .map_err(|_| failed())?;
        if !o.status.success() {
            return Err(failed());
        }
        Ok(String::from_utf8_lossy(&o.stdout)
            .trim_end_matches('\n')
            .to_string())
    }
}

fn job(slug: &str, description: &str, argv: Vec<String>) -> JobSpec {
    JobSpec {
        slug: slug.to_string(),
        description: description.to_string(),
        argv,
    }
}

/// What the action would do. Refuses when the vault is not in the state the action needs.
pub fn plan(action: &Action, paths: &Paths, host: &dyn Host) -> Result<Plan> {
    if !matches!(action, Action::SecretsFix) {
        match VaultState::from_usage(&host.vault_usage(&paths.vault)) {
            VaultState::Open => {}
            VaultState::Closed => {
                return Err(Error::Refused(if matches!(action, Action::Close) {
                    "The vault is closed already.".into()
                } else {
                    "The vault is closed: unlock it first (the unlock page, or hs unlock).".into()
                }));
            }
            VaultState::Absent => {
                return Err(Error::Refused(
                    "There is no vault on this server (hs vault init).".into(),
                ));
            }
        }
    }
    let v = paths.vault.clone();
    let s = paths.secrets.clone();
    Ok(match action {
        Action::HeaderBackup => Plan {
            heading: "save the LUKS header of the vault",
            steps: vec![
                "write the header to /var/lib/hs/vault-header (mode 600, part of the host backup)"
                    .into(),
            ],
            dangers: vec![],
            note: Some("Keep a copy elsewhere too: with the header and the passphrase the vault opens even when the partition is damaged."),
            command: "hs vault header-backup".into(),
            confirm_name: None,
            long: false,
            job: job(
                "vault-header-backup",
                "hs vault header-backup",
                vec!["bash".into(), v, "header-backup".into()],
            ),
        },
        Action::Move(names) => {
            let n = names
                .iter()
                .map(SecretName::as_str)
                .collect::<Vec<_>>()
                .join(" ");
            let what = if names.is_empty() {
                "the usual secrets that exist"
            } else {
                n.as_str()
            };
            let mut argv: Vec<String> = vec!["bash".into(), v, "move".into()];
            argv.extend(names.iter().map(|x| x.as_str().to_string()));
            Plan {
                heading: "move secrets into the vault",
                steps: vec![format!("copy {what} into the vault, check the copy, overwrite the old file and leave a link at the old path")],
                dangers: vec![],
                note: Some("Safe to run again: what is in the vault already is skipped."),
                command: format!("hs vault move {n}"),
                confirm_name: None,
                long: false,
                job: job("vault-move", "hs vault move", argv),
            }
        }
        Action::Close => Plan {
            heading: "close the vault",
            steps: vec!["close the vault; it is refused while something uses it".into()],
            dangers: vec!["Everything that needs a secret (the backup password, the router key, the domain database) waits until the unlock."],
            note: None,
            command: "hs vault close --yes".into(),
            confirm_name: Some("close"),
            long: false,
            job: job(
                "vault-close",
                "hs vault close",
                vec!["bash".into(), v, "close".into(), "--yes".into()],
            ),
        },
        Action::SecretsFix => Plan {
            heading: "set root-only permissions on the secrets",
            steps: vec!["make the files that hold secrets readable by root only (the content of the vault is not touched)".into()],
            dangers: vec![],
            note: None,
            command: "hs secrets fix".into(),
            confirm_name: None,
            long: false,
            job: job(
                "vault-secrets-fix",
                "hs vault secrets-fix",
                vec!["bash".into(), s, "fix".into()],
            ),
        },
    })
}

/// Starts the job of the action; returns the unit name. `close` needs the typed word.
pub fn start(
    action: &Action,
    confirm: Option<&str>,
    paths: &Paths,
    host: &dyn Host,
) -> Result<String> {
    let p = plan(action, paths, host)?;
    if matches!(action, Action::Close) && confirm != Some("close") {
        return Err(Error::Refused("type the word to confirm: close".into()));
    }
    host.start_job(&paths.job_lib, &p.job)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct FakeHost {
        usage: String,
        job: Result<String>,
        calls: RefCell<Vec<String>>,
        jobs: RefCell<Vec<JobSpec>>,
    }

    impl FakeHost {
        fn new(state: &str) -> FakeHost {
            FakeHost {
                usage: if state.is_empty() {
                    String::new()
                } else {
                    format!("state\t{state}\n")
                },
                job: Ok("hs-job-1".into()),
                calls: RefCell::new(Vec::new()),
                jobs: RefCell::new(Vec::new()),
            }
        }
    }

    impl Host for FakeHost {
        fn vault_usage(&self, vault: &str) -> String {
            self.calls.borrow_mut().push(vault.to_string());
            self.usage.clone()
        }
        fn start_job(&self, _job_lib: &str, job: &JobSpec) -> Result<String> {
            self.jobs.borrow_mut().push(job.clone());
            self.job.clone()
        }
    }

    fn paths() -> Paths {
        Paths {
            vault: "/s/vault.sh".into(),
            secrets: "/s/secrets.sh".into(),
            job_lib: "/s/lib/job.sh".into(),
        }
    }

    fn name(s: &str) -> SecretName {
        SecretName::parse(s).unwrap()
    }

    #[test]
    fn names() {
        assert!(SecretName::parse("restic-password").is_some());
        assert!(SecretName::parse(&"a".repeat(61)).is_some());
        for bad in ["a b", "", "-x", ".x", "ä"] {
            assert!(SecretName::parse(bad).is_none(), "{bad}");
        }
        assert!(SecretName::parse(&"a".repeat(62)).is_none());
        assert_eq!(name("a.b").as_str(), "a.b");
    }

    #[test]
    fn actions() {
        for w in ["header-backup", "move", "close", "secrets-fix"] {
            assert_eq!(Action::parse(w).unwrap().word(), w);
        }
        assert!(Action::parse("init").is_none());
    }

    #[test]
    fn usage() {
        assert_eq!(VaultState::from_usage("state\topen\n"), VaultState::Open);
        assert_eq!(
            VaultState::from_usage("x\ty\nstate\tclosed\n"),
            VaultState::Closed
        );
        for s in ["", "state\tweird\n", "state\n"] {
            assert_eq!(VaultState::from_usage(s), VaultState::Absent, "{s:?}");
        }
    }

    #[test]
    fn plans_with_an_open_vault() {
        let h = FakeHost::new("open");
        let p = plan(&Action::HeaderBackup, &paths(), &h).unwrap();
        assert_eq!(p.heading, "save the LUKS header of the vault");
        assert_eq!(p.command, "hs vault header-backup");
        assert_eq!(p.job.argv, ["bash", "/s/vault.sh", "header-backup"]);
        assert!(p.confirm_name.is_none() && p.dangers.is_empty() && !p.long);
        assert!(p.note.unwrap().starts_with("Keep a copy elsewhere"));

        let p = plan(&Action::Move(vec![]), &paths(), &h).unwrap();
        assert_eq!(p.command, "hs vault move ");
        assert_eq!(
            p.steps[0],
            "copy the usual secrets that exist into the vault, check the copy, overwrite the old file and leave a link at the old path"
        );
        assert_eq!(p.job.slug, "vault-move");
        assert_eq!(p.job.argv, ["bash", "/s/vault.sh", "move"]);

        let p = plan(&Action::Move(vec![name("a"), name("b.c")]), &paths(), &h).unwrap();
        assert_eq!(p.command, "hs vault move a b.c");
        assert!(p.steps[0].starts_with("copy a b.c into the vault"));
        assert_eq!(p.job.argv, ["bash", "/s/vault.sh", "move", "a", "b.c"]);

        let p = plan(&Action::Close, &paths(), &h).unwrap();
        assert_eq!(p.confirm_name, Some("close"));
        assert_eq!(p.dangers.len(), 1);
        assert!(p.note.is_none());
        assert_eq!(p.command, "hs vault close --yes");
        assert_eq!(p.job.description, "hs vault close");

        let p = plan(&Action::SecretsFix, &paths(), &h).unwrap();
        assert_eq!(p.command, "hs secrets fix");
        assert_eq!(p.job.slug, "vault-secrets-fix");
        assert_eq!(p.job.description, "hs vault secrets-fix");
        assert_eq!(p.job.argv, ["bash", "/s/secrets.sh", "fix"]);
    }

    #[test]
    fn refuses_when_the_vault_is_closed() {
        let h = FakeHost::new("closed");
        let refused = |a: &Action| plan(a, &paths(), &h).unwrap_err();
        let unlock = Error::Refused(
            "The vault is closed: unlock it first (the unlock page, or hs unlock).".into(),
        );
        assert_eq!(refused(&Action::HeaderBackup), unlock);
        assert_eq!(refused(&Action::Move(vec![])), unlock);
        assert_eq!(
            refused(&Action::Close),
            Error::Refused("The vault is closed already.".into())
        );
        assert!(plan(&Action::SecretsFix, &paths(), &h).is_ok());
        assert_eq!(h.calls.borrow().len(), 3);
    }

    #[test]
    fn secrets_fix_never_asks_the_vault() {
        let h = FakeHost::new("");
        assert!(plan(&Action::SecretsFix, &paths(), &h).is_ok());
        assert!(h.calls.borrow().is_empty());
    }

    #[test]
    fn refuses_without_a_vault() {
        let h = FakeHost::new("");
        assert_eq!(
            plan(&Action::Close, &paths(), &h).unwrap_err(),
            Error::Refused("There is no vault on this server (hs vault init).".into())
        );
    }

    #[test]
    fn close_needs_the_typed_word() {
        let h = FakeHost::new("open");
        for c in [None, Some("nope")] {
            assert_eq!(
                start(&Action::Close, c, &paths(), &h).unwrap_err(),
                Error::Refused("type the word to confirm: close".into())
            );
        }
        assert!(h.jobs.borrow().is_empty());
        assert_eq!(
            start(&Action::Close, Some("close"), &paths(), &h).unwrap(),
            "hs-job-1"
        );
        let jobs = h.jobs.borrow();
        assert_eq!(jobs[0].slug, "vault-close");
        assert_eq!(jobs[0].argv, ["bash", "/s/vault.sh", "close", "--yes"]);
    }

    #[test]
    fn state_comes_before_the_typed_word() {
        let h = FakeHost::new("closed");
        assert_eq!(
            start(&Action::Close, None, &paths(), &h).unwrap_err(),
            Error::Refused("The vault is closed already.".into())
        );
    }

    #[test]
    fn a_job_error_is_failed() {
        let mut h = FakeHost::new("open");
        h.job = Err(Error::Failed("the job could not be started".into()));
        assert_eq!(
            start(&Action::HeaderBackup, None, &paths(), &h).unwrap_err(),
            Error::Failed("the job could not be started".into())
        );
    }
}
