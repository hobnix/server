//! `new`: a queued record for a new job.

use super::failure::failed;
use super::job_id::{clean_slug, new_id};
use super::record::{Record, non_empty};
use super::store::Store;
use super::timestamp::{format_iso, now_whole_seconds};
use crate::Result;

/// The values of `--source`.
pub const SOURCES: [&str; 4] = ["cli", "web", "timer", "extension"];
/// The values of `--kind` of `new` (ADR 0018).
pub const KINDS: [&str; 2] = ["orchestration", "step"];

/// What a new job is: one field per flag of `new`. An empty text means "not given"; `source` must be one of [`SOURCES`].
#[derive(Debug, Clone, Copy, Default)]
pub struct NewJob<'a> {
    pub slug: &'a str,
    pub description: &'a str,
    pub unit: &'a str,
    pub source: &'a str,
    pub initiator: &'a str,
    pub parent: &'a str,
    pub kind: &'a str,
}

impl Store {
    /// `new`: write a queued record, return its id.
    pub fn new_record(&self, job: &NewJob<'_>) -> Result<String> {
        let NewJob {
            slug,
            description,
            unit,
            source,
            initiator,
            parent,
            kind,
        } = *job;
        if !SOURCES.contains(&source) {
            return Err(failed(format!("bad source: {source}")));
        }
        if !kind.is_empty() && !KINDS.contains(&kind) {
            return Err(failed(format!("bad kind: {kind}")));
        }
        if !parent.is_empty() {
            self.path_of(parent)?;
        }
        self.ensure_dir()?;
        let queued = now_whole_seconds();
        let slug = clean_slug(slug);
        let id = new_id(queued, &slug);
        let record = Record {
            id: Some(id.clone()),
            slug: Some(slug),
            description: Some(description.to_string()),
            source: Some(source.to_string()),
            initiator: non_empty(initiator),
            unit: non_empty(unit),
            queued: Some(format_iso(queued)),
            state: Some("queued".to_string()),
            version: Some(1),
            parent: non_empty(parent),
            kind: non_empty(kind),
            ..Record::default()
        };
        self.save(&record)?;
        self.retention();
        Ok(id)
    }
}

#[cfg(test)]
mod tests {
    use crate::jobs::test_support::{TemporaryDirectory, read_file};
    use crate::jobs::{NewJob, Store, valid_id};

    fn queue_cafe_sync(store: &Store) -> String {
        store
            .new_record(&NewJob {
                slug: "-- Pool/Sync!! --",
                description: "Café sync",
                unit: "hs-job-x-1",
                source: "web",
                ..NewJob::default()
            })
            .unwrap()
    }

    #[test]
    fn new_writes_the_documented_record() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = queue_cafe_sync(&store);
        assert!(valid_id(&id), "{id}");
        assert!(id.contains("-Pool-Sync-"));
        let text = read_file(&store, &id);
        let keys = [
            "id",
            "slug",
            "description",
            "source",
            "initiator",
            "unit",
            "queued",
            "started",
            "ended",
            "state",
            "exit",
            "step",
            "progress",
            "error",
            "result",
            "cancel",
            "version",
        ];
        let mut rest = text.as_str();
        for key in keys {
            rest = rest.split_once(&format!("\n  \"{key}\": ")).unwrap().1;
        }
        assert!(text.contains("\"description\": \"Café sync\""));
        assert!(text.contains("\"initiator\": null"));
        assert!(text.contains("\"state\": \"queued\""));
        assert!(text.contains(
            "\"version\": 1,\n  \"parent\": null,\n  \"kind\": null,\n  \"waiting\": null,\n  \"key\": null\n}\n"
        ));
    }

    #[cfg(unix)]
    #[test]
    fn new_sets_the_documented_file_modes() {
        use std::os::unix::fs::PermissionsExt;
        use std::path::Path;
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = queue_cafe_sync(&store);
        let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&store.dir), 0o755);
        assert_eq!(mode(&store.dir.join(format!("{id}.json"))), 0o644);
    }

    #[test]
    fn new_refuses_unknown_values_and_names_an_empty_slug() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let job = NewJob {
            slug: "x",
            description: "d",
            source: "cli",
            ..NewJob::default()
        };
        let refusal = |job: NewJob<'_>| store.new_record(&job).unwrap_err().to_string();
        assert_eq!(
            refusal(NewJob {
                source: "bogus",
                ..job
            }),
            "bad source: bogus"
        );
        assert_eq!(
            refusal(NewJob {
                kind: "bogus",
                ..job
            }),
            "bad kind: bogus"
        );
        assert_eq!(
            refusal(NewJob {
                parent: "bogus",
                ..job
            }),
            "bad job id"
        );
        let unnamed = store.new_record(&NewJob { slug: "!!!", ..job }).unwrap();
        assert!(unnamed.contains("-job-"));
    }
}
