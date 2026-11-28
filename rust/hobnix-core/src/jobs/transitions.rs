//! The changes of a job's state: run, finish, skip, cancel and uncancel.

use super::failure::failed;
use super::record::{Cancel, ErrorInfo, Record, non_empty};
use super::store::Store;
use super::timestamp::now_iso;
use crate::Result;

/// The state, end time and error that follow from the exit status.
fn end_with_exit(record: &mut Record, exit: i64) {
    record.exit = Some(exit);
    record.waiting = None;
    if matches!(record.state.as_deref(), Some("cancelled" | "skipped")) {
        // a cancel stays cancelled, a skip stays skipped (exit 0, no error)
        if record.ended.as_deref().is_none_or(str::is_empty) {
            record.ended = Some(now_iso());
        }
    } else if exit == 0 {
        record.ended = Some(now_iso());
        record.state = Some("ok".to_string());
        record.error = None;
    } else {
        record.ended = Some(now_iso());
        record.state = Some("failed".to_string());
        record.error = Some(ErrorInfo {
            category: "exit".to_string(),
            message: format!("exit status {exit}"),
            ..Default::default()
        });
    }
}

impl Store {
    pub fn run(&self, id: &str) -> Result<()> {
        self.update(id, |record| {
            record.state = Some("running".to_string());
            record.started = Some(now_iso());
            Ok(())
        })
    }

    /// `finish`: a cancelled or skipped record stays as it is (the exit is stored, `ended` and `cancel` stay).
    pub fn finish(&self, id: &str, exit: i64) -> Result<()> {
        self.update(id, |record| {
            end_with_exit(record, exit);
            Ok(())
        })?;
        self.remove_stamps_and_lock(id);
        Ok(())
    }

    /// `skip`: a job that found the same work running ends as skipped (exit 0, the message in `result.message`). Not an error.
    pub fn skip(&self, id: &str, message: &str) -> Result<()> {
        self.update(id, |record| {
            if !record.is_active() {
                return Err(failed("job has ended already"));
            }
            record.state = Some("skipped".to_string());
            record.exit = Some(0);
            record.ended = Some(now_iso());
            record.waiting = None;
            record.error = None;
            let mut result = serde_json::Map::new();
            result.insert(
                "message".to_string(),
                serde_json::Value::String(message.to_string()),
            );
            record.result = Some(serde_json::Value::Object(result));
            Ok(())
        })
    }

    pub fn cancel(&self, id: &str, by: &str, safe: bool) -> Result<()> {
        self.update(id, |record| {
            if !record.is_active() {
                return Err(failed("job already finished"));
            }
            let at = now_iso();
            record.state = Some("cancelled".to_string());
            record.waiting = None;
            record.ended = Some(at.clone());
            record.error = None;
            record.cancel = Some(Cancel {
                requested_by: non_empty(by),
                at,
                safe,
                ..Default::default()
            });
            Ok(())
        })
    }

    /// `uncancel`: the stop of the unit failed after the record was marked cancelled; the job still runs, so the record says so again.
    pub fn uncancel(&self, id: &str) -> Result<()> {
        self.update(id, |record| {
            if record.state.as_deref() != Some("cancelled") || record.exit.is_some() {
                return Err(failed("job is not cancelled, or it ended already"));
            }
            let state = if record.started.is_some() {
                "running"
            } else {
                "queued"
            };
            record.state = Some(state.to_string());
            record.ended = None;
            record.cancel = None;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use crate::jobs::test_support::{TemporaryDirectory, new_job, read_file};

    #[test]
    fn uncancel_puts_the_record_back() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = new_job(&store, "hs-job-un-0320");
        store.run(&id).unwrap();
        store.cancel(&id, "bob", true).unwrap();
        store.uncancel(&id).unwrap();
        let record = store.load(&id).unwrap();
        assert_eq!(record.state.as_deref(), Some("running"));
        assert!(record.ended.is_none() && record.cancel.is_none());
        assert!(store.uncancel(&id).is_err());
    }

    #[test]
    fn cancel_finish_and_find_unit() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = new_job(&store, "hs-job-gc-0320");
        assert_eq!(store.find_unit("hs-job-gc-0320.service").unwrap(), id);
        assert_eq!(store.find_unit("hs-job-gc-0320").unwrap(), id);
        assert_eq!(
            store.find_unit("other").unwrap_err().to_string(),
            "no running job record for other"
        );
        assert!(!store.is_cancelled(&id).unwrap());
        store.cancel(&id, "bob", true).unwrap();
        assert!(store.is_cancelled(&id).unwrap());
        let ended = store.load(&id).unwrap().ended;
        assert!(ended.is_some());
        store.finish(&id, 143).unwrap();
        let record = store.load(&id).unwrap();
        assert_eq!(record.state.as_deref(), Some("cancelled"));
        assert_eq!(record.exit, Some(143));
        assert_eq!(record.ended, ended);
        let cancel = record.cancel.unwrap();
        assert_eq!(cancel.requested_by.as_deref(), Some("bob"));
        assert!(cancel.safe);
        assert_eq!(
            store.cancel(&id, "bob", true).unwrap_err().to_string(),
            "job already finished"
        );
        assert!(store.find_unit("hs-job-gc-0320").is_err());
    }

    #[test]
    fn a_skipped_job_stays_skipped() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = new_job(&store, "hs-job-x-2");
        store.skip(&id, "Already running").unwrap();
        assert!(store.skip(&id, "again").is_err());
        store.finish(&id, 1).unwrap();
        let text = read_file(&store, &id);
        assert!(text.contains("\"state\": \"skipped\""));
        assert!(text.contains("\"exit\": 1"));
        assert!(text.contains("\"message\": \"Already running\""));
    }
}
