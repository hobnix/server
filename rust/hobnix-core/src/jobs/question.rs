//! A job that waits for an answer (ADR 0018).

use super::failure::failed;
use super::record::{Waiting, non_empty};
use super::store::Store;
use super::timestamp::now_iso;
use crate::Result;

/// The values of `--kind` of a question.
pub const ASK_KINDS: [&str; 3] = ["text", "secret", "choice"];

/// The question given to `wait`.
#[derive(Debug, Clone, Default)]
pub struct Question<'a> {
    pub seq: i64,
    pub key: &'a str,
    pub label: &'a str,
    pub kind: &'a str,
    pub default: &'a str,
    pub pattern: &'a str,
    pub choices: &'a str,
    pub error: &'a str,
    pub attempt: i64,
}

/// The question as the record keeps it; `choices` is a comma-separated list.
fn pending(question: &Question<'_>) -> Waiting {
    let choices: Vec<String> = question
        .choices
        .split(',')
        .filter(|choice| !choice.is_empty())
        .map(str::to_string)
        .collect();
    Waiting {
        seq: question.seq,
        key: question.key.to_string(),
        label: question.label.to_string(),
        kind: question.kind.to_string(),
        default: if question.kind == "secret" {
            None
        } else {
            non_empty(question.default)
        },
        pattern: non_empty(question.pattern),
        choices: (!choices.is_empty()).then_some(choices),
        error: non_empty(question.error),
        attempt: question.attempt,
        asked: now_iso(),
        ..Default::default()
    }
}

impl Store {
    /// `wait`: a question is pending, the state is `waiting`.
    pub fn wait(&self, id: &str, q: &Question<'_>) -> Result<()> {
        if !ASK_KINDS.contains(&q.kind) {
            return Err(failed(format!("bad question kind: {}", q.kind)));
        }
        self.update(id, |record| {
            if !matches!(record.state.as_deref(), Some("running" | "waiting")) {
                return Err(failed("job is not running"));
            }
            record.state = Some("waiting".to_string());
            record.waiting = Some(pending(q));
            Ok(())
        })
    }

    /// `resume`: the question was answered, waiting goes back to running.
    pub fn resume(&self, id: &str) -> Result<()> {
        self.update(id, |record| {
            if record.state.as_deref() != Some("waiting") {
                return Err(failed("job is not waiting"));
            }
            record.state = Some("running".to_string());
            record.waiting = None;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jobs::test_support::{TemporaryDirectory, new_job, read_file};
    use std::fs;

    #[test]
    fn a_waiting_job_keeps_no_secret_default_and_can_resume() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = new_job(&store, "hs-job-w-1");
        store.run(&id).unwrap();
        let secret = Question {
            seq: 1,
            key: "PW",
            label: "Password",
            kind: "secret",
            default: "hunter2",
            attempt: 1,
            ..Default::default()
        };
        store.wait(&id, &secret).unwrap();
        let record = store.load(&id).unwrap();
        assert_eq!(record.state.as_deref(), Some("waiting"));
        assert_eq!(
            record.waiting.as_ref().unwrap().default,
            None,
            "no default for a secret"
        );
        assert!(!read_file(&store, &id).contains("hunter2"));
        let bogus = Question {
            kind: "bogus",
            ..Default::default()
        };
        assert!(store.wait(&id, &bogus).is_err());
        assert_eq!(store.find_unit("hs-job-w-1").unwrap(), id);
        store.resume(&id).unwrap();
        assert_eq!(store.load(&id).unwrap().waiting, None);
        assert!(store.resume(&id).is_err());
    }

    #[test]
    fn a_sparse_question_of_another_writer_loads_and_cancel_clears_it() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = new_job(&store, "hs-job-w-1");
        store.run(&id).unwrap();
        let path = temporary.0.join(format!("{id}.json"));
        let text = read_file(&store, &id).replace("\"waiting\": null", "\"waiting\": {\"seq\": 1}");
        fs::write(&path, text).unwrap();
        assert_eq!(store.load(&id).unwrap().waiting.unwrap().seq, 1);
        store.cancel(&id, "bob", true).unwrap();
        assert_eq!(store.load(&id).unwrap().waiting, None);
    }

    #[test]
    fn choices_are_split_at_commas() {
        let question = Question {
            kind: "choice",
            default: "b",
            choices: "a,,b,",
            ..Default::default()
        };
        let waiting = pending(&question);
        assert_eq!(waiting.choices, Some(vec!["a".into(), "b".into()]));
        assert_eq!(waiting.default.as_deref(), Some("b"));
        assert_eq!(waiting.pattern, None);
        assert_eq!(pending(&Question::default()).choices, None);
    }
}
