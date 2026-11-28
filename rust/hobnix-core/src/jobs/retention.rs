//! How long records are kept.

use super::store::{Store, record_id};
use super::timestamp::{now_epoch_seconds, seconds_between};
use std::fs;
use std::time::UNIX_EPOCH;

/// Records beyond the newest `KEEP_COUNT` are removed when they are also older than `KEEP_DAYS`.
pub const KEEP_COUNT: usize = 200;
pub const KEEP_DAYS: f64 = 30.0;

impl Store {
    /// Remove records beyond the newest `KEEP_COUNT` that are also older than `KEEP_DAYS`, with their `<id>.*` files.
    pub(super) fn retention(&self) {
        let Some(names) = self.record_file_names() else {
            return;
        };
        let records = self.newest_first(names);
        let limit = now_epoch_seconds() - KEEP_DAYS * 86_400.0;
        for (modified, name) in records.into_iter().skip(KEEP_COUNT) {
            if modified < limit {
                self.prune(&name);
            }
        }
    }

    /// (modification time, file name), the newest first; a file whose time cannot be read is left out.
    fn newest_first(&self, names: Vec<String>) -> Vec<(f64, String)> {
        let mut records: Vec<(f64, String)> = names
            .into_iter()
            .filter_map(|name| {
                let metadata = fs::metadata(self.dir.join(&name)).ok()?;
                let modified = seconds_between(UNIX_EPOCH, metadata.modified().ok()?);
                Some((modified, name))
            })
            .collect();
        records.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
        records
    }

    /// Remove one record file and its `<id>.*` files, unless the job is still active.
    fn prune(&self, name: &str) {
        let Some(id) = record_id(name) else {
            return;
        };
        // a job that waits for an answer can wait for days: never pruned while active
        if self.load(id).is_ok_and(|record| record.is_active()) {
            return;
        }
        let prefix = format!("{id}.");
        let mut victims = vec![name.to_string()];
        if let Ok(entries) = fs::read_dir(&self.dir) {
            victims.extend(
                entries
                    .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
                    .filter(|other| other.starts_with(&prefix) && other != name),
            );
        }
        for victim in victims {
            let _ = fs::remove_file(self.dir.join(victim));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jobs::Question;
    use crate::jobs::test_support::{TemporaryDirectory, new_job};
    use std::time::{Duration, SystemTime};

    const FORTY_DAYS: Duration = Duration::from_hours(40 * 24);

    #[test]
    fn retention_keeps_new_and_young() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        fs::create_dir_all(&store.dir).unwrap();
        let old = SystemTime::now() - FORTY_DAYS;
        let make = |name: &str, when: SystemTime| {
            let file = fs::File::create(store.dir.join(name)).unwrap();
            file.set_modified(when).unwrap();
        };
        for i in 0..KEEP_COUNT {
            make(
                &format!("20240101-000000-keep{i:03}-abcd.json"),
                SystemTime::now(),
            );
        }
        make("20230101-000000-old-abcd.json", old);
        make("20230101-000000-old-abcd.step.stamp", old);
        make("20230101-000000-older-abcd.json", old);
        // an old record inside the newest KEEP_COUNT stays: all 200 fresh ones are newer, so the old ones go
        store.retention();
        let exists = |name: &str| store.dir.join(name).exists();
        assert!(!exists("20230101-000000-old-abcd.json"));
        assert!(!exists("20230101-000000-old-abcd.step.stamp"));
        assert!(!exists("20230101-000000-older-abcd.json"));
        assert!(exists("20240101-000000-keep000-abcd.json"));
        // fresh records beyond the count stay while they are young
        make("20240101-000000-extra-abcd.json", SystemTime::now());
        store.retention();
        assert!(exists("20240101-000000-extra-abcd.json"));
    }

    #[test]
    fn an_old_waiting_record_survives_and_an_old_finished_one_does_not() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let waiting = new_job(&store, "hs-job-w-2");
        store.run(&waiting).unwrap();
        let question = Question {
            seq: 1,
            key: "K",
            label: "L",
            kind: "text",
            attempt: 1,
            ..Default::default()
        };
        store.wait(&waiting, &question).unwrap();
        let done = new_job(&store, "hs-job-w-3");
        store.run(&done).unwrap();
        store.finish(&done, 0).unwrap();
        let old = SystemTime::now() - FORTY_DAYS;
        for (id, earlier_by) in [(&waiting, 5), (&done, 1)] {
            let file = fs::File::options()
                .write(true)
                .open(temporary.0.join(format!("{id}.json")))
                .unwrap();
            file.set_modified(old - Duration::from_secs(earlier_by))
                .unwrap();
        }
        for _ in 0..KEEP_COUNT {
            new_job(&store, "hs-job-fill");
        }
        store.retention();
        let exists = |id: &str| temporary.0.join(format!("{id}.json")).exists();
        assert!(exists(&waiting), "waiting is kept");
        assert!(!exists(&done), "an old finished one goes");
    }
}
