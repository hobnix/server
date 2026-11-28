//! `hobnix event-emit <source>.<kind> <subject> [text] [--level L] [--payload JSON]`: the words, exit codes and environment of
//! `state-db.py emit`, answered by hobnix-core. Not in use: the writer of the event log is state-db.py (hobnix/core#1336).
//!
//! Exit codes follow state-db.py: 0 written, 1 refused or database error (a missing database too), 2 usage.

use crate::output;
use hobnix_core::db::StateDb;
use hobnix_core::events::{self, EmitRequest, EventName, KindFiles, Level, Retention};
use hobnix_core::{EXIT_OK, Error, Result};
use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

const EXIT_USAGE: u8 = 2;
const USAGE: &str = "usage: emit <source>.<kind> <subject> [text] [--level info|warn|error] [--payload JSON]  (a kind is <source>.<kind>, lower case)";
const BAD_LEVEL: &str = "level is info, warn or error";

/// The request in the words, or the usage line to print. As in state-db.py, an option without a value is an ordinary word, the last of
/// a repeated option counts and words after the text are ignored.
fn parse(args: &[String]) -> std::result::Result<EmitRequest, &'static str> {
    let (mut words, mut level, mut payload) = (Vec::new(), None, None);
    let mut rest = args.iter();
    while let Some(word) = rest.next() {
        let option = match word.as_str() {
            "--level" => &mut level,
            "--payload" => &mut payload,
            _ => {
                words.push(word);
                continue;
            }
        };
        match rest.next() {
            Some(value) => *option = Some(value.clone()),
            None => words.push(word),
        }
    }
    let name = words
        .first()
        .and_then(|w| EventName::parse(w))
        .ok_or(USAGE)?;
    let level = match level {
        Some(text) => Some(Level::parse(&text).ok_or(BAD_LEVEL)?),
        None => None,
    };
    let word = |at: usize| words.get(at).map_or_else(String::new, |w| (*w).clone());
    Ok(EmitRequest {
        name,
        subject: word(1),
        text: word(2),
        level,
        payload,
    })
}

/// The environment of state-db.py, read here only.
struct Environment<F>(F);

impl<F: Fn(&str) -> Option<OsString>> Environment<F> {
    /// A variable that is set and not empty.
    fn filled(&self, name: &str) -> Option<PathBuf> {
        (self.0)(name).filter(|v| !v.is_empty()).map(PathBuf::from)
    }

    fn state_dir(&self) -> PathBuf {
        (self.0)("HS_STATE_DIR").map_or_else(|| PathBuf::from("/var/lib/hs"), PathBuf::from)
    }

    fn database(&self) -> PathBuf {
        (self.0)("HS_STATE_DB").map_or_else(|| self.state_dir().join("state.db"), PathBuf::from)
    }

    /// The scripts: `HS_SCRIPTS` as `hs` exports it, else where a server has them.
    fn kind_files(&self) -> KindFiles {
        let installed = self.filled("HS_PKG_EVENTS_DIR").unwrap_or_else(|| {
            self.filled("HS_STATE_DIR")
                .unwrap_or_else(|| PathBuf::from("/var/lib/hs"))
                .join("pkg-events")
        });
        KindFiles {
            scripts: self
                .filled("HS_SCRIPTS")
                .unwrap_or_else(|| PathBuf::from("/etc/nixos/scripts")),
            installed,
        }
    }

    fn socket(&self) -> PathBuf {
        self.filled("HS_LIVE_SOCK").unwrap_or_else(|| {
            self.filled("HS_RUN_DIR")
                .unwrap_or_else(|| PathBuf::from("/run/hs"))
                .join("live.sock")
        })
    }

    /// A whole number; `unset` when the variable is not there. Set to anything else it is an error, as for python's `int()`.
    fn number(&self, name: &str, unset: i64) -> Result<i64> {
        let Some(value) = (self.0)(name) else {
            return Ok(unset);
        };
        value
            .to_str()
            .and_then(|text| text.trim().parse().ok())
            .ok_or_else(|| Error::Failed(format!("{name} is not a whole number")))
    }

    fn retention(&self) -> Result<Retention> {
        let standard = Retention::default();
        Ok(Retention {
            keep: self.number("HS_EVENT_KEEP", standard.keep)?,
            days: self.number("HS_EVENT_DAYS", standard.days)?,
            ephemeral_days: self.number("HS_EVENT_EPHEMERAL_DAYS", standard.ephemeral_days)?,
            metric_days: self.number("HS_EVENT_METRIC_DAYS", standard.metric_days)?,
        })
    }

    /// `HS_NOW` (tests), when it is set and not empty, else the clock.
    fn now(&self) -> Result<i64> {
        if self.filled("HS_NOW").is_some() {
            return self.number("HS_NOW", 0);
        }
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|since| i64::try_from(since.as_secs()).ok())
            .ok_or_else(|| Error::Failed("the clock is before 1970".into()))
    }
}

fn write(request: &EmitRequest) -> Result<()> {
    let environment = Environment(|name: &str| std::env::var_os(name));
    let retention = environment.retention()?;
    let mut db = StateDb::open_rw(&environment.database())?;
    let now = environment.now()?;
    events::emit(&mut db, now, request, retention, &environment.kind_files())?;
    drop(db);
    // best effort: whether anybody listens does not change the result
    events::poke(&environment.socket());
    Ok(())
}

pub(crate) fn run(args: &[String]) -> Result<u8> {
    let request = match parse(args) {
        Ok(request) => request,
        Err(usage) => {
            let written = output::error_line(format_args!("hobnix: {usage}"));
            return Ok(output::exit_with(written, EXIT_USAGE));
        }
    };
    match write(&request) {
        Ok(()) => Ok(EXIT_OK),
        // a missing database is exit 1 here, not the 2 of other commands: 2 means usage
        Err(Error::Missing(reason)) => Err(Error::Failed(reason)),
        Err(other) => Err(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(args: &[&str]) -> Vec<String> {
        args.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn options_may_stand_anywhere_and_the_last_one_counts() {
        let request = parse(&words(&[
            "--level",
            "info",
            "a.b",
            "s",
            "--payload",
            "{}",
            "t",
            "more",
            "--level",
            "warn",
        ]))
        .expect("request");
        assert_eq!(
            (request.subject.as_str(), request.text.as_str()),
            ("s", "t")
        );
        assert_eq!(request.level, Some(Level::Warn));
        assert_eq!(request.payload.as_deref(), Some("{}"));
    }

    #[test]
    fn an_option_without_a_value_is_a_word() {
        let request = parse(&words(&["a.b", "--level"])).expect("request");
        assert_eq!(request.subject, "--level");
        assert_eq!(request.level, None);
    }

    #[test]
    fn a_bad_kind_or_level_is_a_usage_error() {
        assert_eq!(parse(&[]), Err(USAGE));
        assert_eq!(parse(&words(&["storage"])), Err(USAGE));
        assert_eq!(parse(&words(&["a.b", "--level", "loud"])), Err(BAD_LEVEL));
    }

    fn environment(set: &'static [(&str, &str)]) -> Environment<impl Fn(&str) -> Option<OsString>> {
        Environment(move |name: &str| {
            set.iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| OsString::from(value))
        })
    }

    #[test]
    fn the_defaults_are_those_of_the_server() {
        let unset = environment(&[]);
        assert_eq!(unset.database(), PathBuf::from("/var/lib/hs/state.db"));
        assert_eq!(unset.socket(), PathBuf::from("/run/hs/live.sock"));
        assert_eq!(
            unset.kind_files().installed,
            PathBuf::from("/var/lib/hs/pkg-events")
        );
        assert_eq!(unset.retention(), Ok(Retention::default()));
    }

    #[test]
    fn a_number_that_is_none_is_an_error() {
        assert!(environment(&[("HS_EVENT_KEEP", "")]).retention().is_err());
        assert!(
            environment(&[("HS_EVENT_DAYS", "ten")])
                .retention()
                .is_err()
        );
        assert_eq!(environment(&[("HS_NOW", " 5 ")]).now(), Ok(5));
    }
}
