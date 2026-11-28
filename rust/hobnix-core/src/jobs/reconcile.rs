//! `reconcile`: the records of jobs that ended without saying so, after a restart or a stopped unit.

use super::record::{ErrorInfo, Record};
use super::store::{Store, record_id};
use super::system::System;
use super::timestamp::{floor_seconds, format_iso, now_iso, parse_iso, seconds_as_float};
use crate::Result;

/// What a reconcile run did: one line per record marked interrupted (id, slug, description) and the failures.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Reconciled {
    pub lines: Vec<(String, String, String)>,
    pub errors: Vec<String>,
}

/// A field of a tab-separated output line: no tabs or line breaks, `-` when empty.
fn one_line(text: Option<&str>) -> String {
    let mut out = String::new();
    let mut in_break = false;
    for character in text.unwrap_or("").chars() {
        if matches!(character, '\t' | '\r' | '\n') {
            if !in_break {
                out.push(' ');
                in_break = true;
            }
        } else {
            out.push(character);
            in_break = false;
        }
    }
    match out.trim() {
        "" => "-".to_string(),
        trimmed => trimmed.to_string(),
    }
}

/// When the job started, or was queued if it never started.
fn began_at(record: &Record) -> Option<i64> {
    let text = match record.started.as_deref() {
        Some(started) if !started.is_empty() => Some(started),
        _ => record.queued.as_deref(),
    };
    text.and_then(parse_iso)
}

/// Mark as interrupted. It ended when the machine booted, or now when that cannot be told.
fn interrupt(record: &mut Record, ended_by_boot: Option<f64>) {
    record.ended = Some(match ended_by_boot {
        Some(boot) => format_iso(floor_seconds(boot)),
        None => now_iso(),
    });
    record.state = Some("interrupted".to_string());
    record.waiting = None;
    record.exit = None;
    record.error = Some(ErrorInfo {
        category: "interrupted".to_string(),
        message: "the job did not finish; the server restarted or the unit stopped".to_string(),
        ..Default::default()
    });
}

impl Store {
    /// `reconcile`: mark queued/running records whose unit is gone as interrupted. Never re-runs anything.
    pub fn reconcile(&self, sys: &dyn System) -> Reconciled {
        let mut out = Reconciled::default();
        let Some(mut names) = self.record_file_names() else {
            return out;
        };
        // by file name, not by id: `a-b.json` sorts before `a.json`
        names.sort();
        let boot = sys.boot_time();
        for id in names.iter().filter_map(|name| record_id(name)) {
            match self.reconcile_one(id, boot, sys) {
                Ok(Some(line)) => out.lines.push(line),
                Ok(None) => {}
                Err(error) => out.errors.push(error.to_string()),
            }
        }
        out
    }

    fn reconcile_one(
        &self,
        id: &str,
        boot: Option<f64>,
        system: &dyn System,
    ) -> Result<Option<(String, String, String)>> {
        // no lock yet, so a finished record leaves no lock file behind
        if !self.load(id)?.is_active() {
            return Ok(None);
        }
        let marked = self.locked(id, || self.interrupt_if_gone(id, boot, system))?;
        let Some(record) = marked else {
            return Ok(None);
        };
        self.remove_stamps_and_lock(id);
        Ok(Some((
            id.to_string(),
            one_line(record.slug.as_deref()),
            one_line(record.description.as_deref()),
        )))
    }

    /// The record as saved when its job was marked; None when it is left alone. The caller holds the lock.
    fn interrupt_if_gone(
        &self,
        id: &str,
        boot: Option<f64>,
        system: &dyn System,
    ) -> Result<Option<Record>> {
        let mut record = self.load(id)?;
        if !record.is_active() {
            return Ok(None);
        }
        let began = began_at(&record);
        if let (Some(boot), Some(began)) = (boot, began)
            && seconds_as_float(began) >= boot
        {
            // started after this boot (a job may be between its record and its unit): not a restart victim
            return Ok(None);
        }
        if system.unit_alive(record.unit.as_deref().unwrap_or("")) {
            return Ok(None);
        }
        interrupt(&mut record, boot.filter(|_| began.is_some()));
        self.save(&record)?;
        Ok(Some(record))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jobs::test_support::{FakeSystem, TemporaryDirectory, new_job};
    use crate::jobs::timestamp::now_epoch_seconds;
    use std::fs;

    #[test]
    fn reconcile_marks_only_the_gone_ones() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let gone = new_job(&store, "hs-job-gone");
        let alive = new_job(&store, "hs-job-alive");
        let done = new_job(&store, "hs-job-done");
        let fresh = new_job(&store, "hs-job-fresh");
        store.finish(&done, 0).unwrap();
        for id in [&gone, &alive] {
            let mut record = store.load(id).unwrap();
            record.started = Some("2024-01-01T00:00:00Z".into());
            record.description = Some("line\none\ttwo".into());
            store.save(&record).unwrap();
        }
        let boot = seconds_as_float(parse_iso("2024-06-01T00:00:30Z").unwrap());
        // `fresh` was queued now, after the fake boot
        let reconciled = store.reconcile(&FakeSystem {
            alive: vec!["hs-job-alive"],
            boot: Some(boot),
        });
        assert!(reconciled.errors.is_empty());
        assert_eq!(reconciled.lines.len(), 1, "{:?}", reconciled.lines);
        let line = reconciled.lines.iter().find(|line| line.0 == gone).unwrap();
        assert_eq!(line.1, "pool-sync");
        assert_eq!(line.2, "line one two");
        let record = store.load(&gone).unwrap();
        assert_eq!(record.state.as_deref(), Some("interrupted"));
        assert_eq!(record.ended.as_deref(), Some("2024-06-01T00:00:30Z"));
        assert_eq!(record.exit, None);
        assert_eq!(record.error.unwrap().category, "interrupted");
        assert!(!store.lock_path(&gone).exists());
        // the alive one and the one queued after boot stay as they are
        let state = |id: &str| store.load(id).unwrap().state.unwrap();
        assert_eq!(state(&alive), "queued");
        assert_eq!(state(&fresh), "queued");
        assert_eq!(state(&done), "ok");
    }

    #[test]
    fn reconcile_spares_jobs_that_began_after_boot_and_reports_bad_records() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = new_job(&store, "hs-job-new");
        let system = FakeSystem {
            alive: vec![],
            boot: Some(now_epoch_seconds() - 100.0),
        };
        fs::write(store.dir.join("garbage.json"), "{}").unwrap();
        let reconciled = store.reconcile(&system);
        assert!(reconciled.lines.is_empty());
        assert_eq!(reconciled.errors, vec!["bad job id".to_string()]);
        assert_eq!(store.load(&id).unwrap().state.as_deref(), Some("queued"));
        // without a boot time the unit decides
        let system = FakeSystem {
            alive: vec![],
            boot: None,
        };
        assert_eq!(store.reconcile(&system).lines.len(), 1);
        assert_eq!(
            store.load(&id).unwrap().state.as_deref(),
            Some("interrupted")
        );
    }

    #[test]
    fn reconcile_without_a_directory_is_empty() {
        let temporary = TemporaryDirectory::new();
        let reconciled = temporary.store().reconcile(&FakeSystem {
            alive: vec![],
            boot: None,
        });
        assert_eq!(reconciled, Reconciled::default());
    }

    #[test]
    fn one_line_collapses() {
        assert_eq!(one_line(None), "-");
        assert_eq!(one_line(Some(" \n\t ")), "-");
        assert_eq!(one_line(Some("a\r\n\tb ")), "a b");
    }
}
