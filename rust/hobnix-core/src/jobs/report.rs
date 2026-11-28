//! What is written into a record besides its state: step, progress, row key, result and the reason of an end.

use super::failure::failed;
use super::record::{ErrorInfo, Progress, Record, Step};
use super::store::Store;
use crate::Result;

/// The longest `result` text, in characters.
const RESULT_MAX_CHARS: usize = 4096;

/// A `result` value: one flat JSON object whose values are strings or numbers (no booleans, nulls, lists, objects).
fn parse_flat_result(json: &str) -> Result<serde_json::Map<String, serde_json::Value>> {
    let value: serde_json::Value =
        serde_json::from_str(json).map_err(|_| failed("result is not JSON"))?;
    let flat = |value: &serde_json::Value| value.is_string() || value.is_number();
    match value {
        serde_json::Value::Object(map)
            if json.chars().count() <= RESULT_MAX_CHARS && map.values().all(flat) =>
        {
            Ok(map)
        }
        _ => Err(failed(
            "result must be one flat JSON object of strings and numbers, at most 4 KB",
        )),
    }
}

impl Store {
    /// `key`: the row key (web/src/jobkey.js). Same cleaning as job-record.py: only A-Za-z0-9 and space . _ : / = @ , + -, trimmed, 200 characters at most.
    pub fn set_key(&self, id: &str, key: &str) -> Result<()> {
        let allowed: String = key
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || " ._:/=@,+-".contains(*c))
            .collect();
        let clean: String = allowed.trim().chars().take(200).collect();
        self.update(id, |record| {
            record.key = (!clean.is_empty()).then_some(clean);
            Ok(())
        })
    }

    pub fn step(&self, id: &str, n: i64, of: i64, text: &str) -> Result<()> {
        self.update_rate_limited(id, "step", n == of, |record| {
            record.step = Some(Step {
                n,
                of,
                text: text.to_string(),
                ..Default::default()
            });
        })
    }

    pub fn progress(&self, id: &str, done: i64, total: i64, unit: &str) -> Result<()> {
        self.update_rate_limited(id, "progress", done == total, |record| {
            record.progress = Some(Progress {
                done,
                total,
                unit: unit.to_string(),
                ..Default::default()
            });
        })
    }

    /// A write that is dropped when the last one of its `kind` was too recent; the last one of a count always happens.
    fn update_rate_limited(
        &self,
        id: &str,
        kind: &str,
        is_last: bool,
        change: impl FnOnce(&mut Record),
    ) -> Result<()> {
        if self.is_rate_limited(id, kind) && !is_last {
            return Ok(());
        }
        self.update(id, |record| {
            change(record);
            Ok(())
        })?;
        self.touch_stamp(id, kind);
        Ok(())
    }

    /// `error`: name why an ended job ended (ADR 0018: `input_timeout`, `input_rejected`). Only a record that ended; state and exit stay.
    /// `code` (ADR 0028) is the catalogue code of the refusal that ended the job; absent when none is known.
    pub fn set_error(
        &self,
        id: &str,
        category: &str,
        message: &str,
        code: Option<&str>,
    ) -> Result<()> {
        self.update(id, |record| {
            if record.is_active() {
                return Err(failed("job has not ended"));
            }
            let mut extra = serde_json::Map::new();
            if let Some(code) = code.filter(|code| !code.is_empty()) {
                extra.insert(
                    "code".to_string(),
                    serde_json::Value::String(code.to_string()),
                );
            }
            record.error = Some(ErrorInfo {
                category: category.to_string(),
                message: message.to_string(),
                extra,
            });
            Ok(())
        })
    }

    /// `result`: what a job made (PLAN-app-lifecycle Q2). One flat JSON object of strings and numbers, at most 4096 characters; any state.
    pub fn set_result(&self, id: &str, json: &str) -> Result<()> {
        let object = parse_flat_result(json)?;
        self.update(id, |record| {
            record.result = Some(serde_json::Value::Object(object));
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jobs::NewJob;
    use crate::jobs::test_support::{TemporaryDirectory, new_job, read_file};

    #[test]
    fn the_row_key_is_cleaned_and_survives_a_rewrite() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = store
            .new_record(&NewJob {
                slug: "pool-sync",
                description: "d",
                unit: "u",
                source: "cli",
                ..NewJob::default()
            })
            .unwrap();
        store.set_key(&id, "bad;$(x) key").unwrap();
        assert!(read_file(&store, &id).contains("\"key\": \"badx key\""));
        store.run(&id).unwrap();
        store.finish(&id, 0).unwrap();
        assert!(read_file(&store, &id).contains("\"key\": \"badx key\""));
        store.set_key(&id, "pool sync tank").unwrap();
        assert!(read_file(&store, &id).contains("\"key\": \"pool sync tank\""));
    }

    #[test]
    fn run_step_progress_finish() {
        let temporary = TemporaryDirectory::new();
        let mut store = temporary.store();
        store.rate = 60.0;
        let id = new_job(&store, "hs-job-pool-sync-1");
        store.run(&id).unwrap();
        store.step(&id, 1, 3, "first").unwrap();
        store.step(&id, 2, 3, "dropped by the rate limit").unwrap();
        store.step(&id, 3, 3, "last always counts").unwrap();
        store.progress(&id, 5, 10, "files").unwrap();
        store.progress(&id, 6, 10, "files").unwrap();
        let record = store.load(&id).unwrap();
        assert_eq!(record.state.as_deref(), Some("running"));
        assert_eq!(record.step.unwrap().text, "last always counts");
        assert_eq!(record.progress.unwrap().done, 5);
        assert!(store.stamp_path(&id, "step").exists());
        store.finish(&id, 3).unwrap();
        let record = store.load(&id).unwrap();
        assert_eq!(record.state.as_deref(), Some("failed"));
        assert_eq!(record.exit, Some(3));
        assert_eq!(record.error.unwrap().message, "exit status 3");
        assert!(!store.stamp_path(&id, "step").exists());
        assert!(!store.lock_path(&id).exists());
        store.finish(&id, 0).unwrap();
        let record = store.load(&id).unwrap();
        assert_eq!(record.state.as_deref(), Some("ok"));
        assert!(record.error.is_none());
    }

    #[test]
    fn an_ended_job_takes_an_error_and_a_result() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = new_job(&store, "hs-job-x-1");
        assert!(
            store.set_error(&id, "c", "m", None).is_err(),
            "an active job has not ended"
        );
        store.run(&id).unwrap();
        store.finish(&id, 2).unwrap();
        store
            .set_error(&id, "input_timeout", "no answer", Some("job.busy"))
            .unwrap();
        store.set_result(&id, r#"{"b": "2", "a": 1}"#).unwrap();
        let text = read_file(&store, &id);
        assert!(text.contains("\"category\": \"input_timeout\""));
        assert!(text.contains("\"code\": \"job.busy\""));
        assert!(text.contains("\"state\": \"failed\""));
        assert!(
            text.find("\"b\"") < text.find("\"a\""),
            "result keeps the order given"
        );
        for bad in [
            "{oops",
            "[1]",
            r#"{"a": {"b": 1}}"#,
            r#"{"a": true}"#,
            r#"{"a": null}"#,
        ] {
            assert!(store.set_result(&id, bad).is_err(), "{bad}");
        }
        let long = format!(r#"{{"a": "{}"}}"#, "x".repeat(RESULT_MAX_CHARS));
        assert!(store.set_result(&id, &long).is_err());
    }
}
