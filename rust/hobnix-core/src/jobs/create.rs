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

impl Store {
    /// `new`: write a queued record, return its id.
    #[expect(
        clippy::too_many_arguments,
        reason = "one argument per flag of `new`; a struct would only move them"
    )]
    pub fn new_record(
        &self,
        slug: &str,
        desc: &str,
        unit: &str,
        source: &str,
        initiator: &str,
        parent: &str,
        kind: &str,
    ) -> Result<String> {
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
            description: Some(desc.to_string()),
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
    use crate::jobs::{Store, valid_id};

    fn queue_cafe_sync(store: &Store) -> String {
        store
            .new_record(
                "-- Pool/Sync!! --",
                "Café sync",
                "hs-job-x-1",
                "web",
                "",
                "",
                "",
            )
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
        let refusal = |source: &str, parent: &str, kind: &str| {
            store
                .new_record("x", "d", "", source, "", parent, kind)
                .unwrap_err()
                .to_string()
        };
        assert_eq!(refusal("bogus", "", ""), "bad source: bogus");
        assert_eq!(refusal("cli", "", "bogus"), "bad kind: bogus");
        assert_eq!(refusal("cli", "bogus", ""), "bad job id");
        assert!(
            store
                .new_record("!!!", "d", "", "cli", "", "", "")
                .unwrap()
                .contains("-job-")
        );
    }
}
