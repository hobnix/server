//! What the tests of the job store share.

use super::{Store, System};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static COUNTER: AtomicU32 = AtomicU32::new(0);

/// A directory of its own for one test, removed at the end. It is not made yet: the store does that.
pub(super) struct TemporaryDirectory(pub(super) PathBuf);

impl TemporaryDirectory {
    pub(super) fn new() -> TemporaryDirectory {
        let number = COUNTER.fetch_add(1, Ordering::SeqCst);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |duration| duration.as_nanos());
        let path = std::env::temp_dir().join(format!(
            "hobnix-jobs-test-{}-{number}-{nanos}",
            std::process::id()
        ));
        TemporaryDirectory(path)
    }

    pub(super) fn store(&self) -> Store {
        Store::new(&self.0)
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

pub(super) struct FakeSystem {
    pub(super) alive: Vec<&'static str>,
    pub(super) boot: Option<f64>,
}

impl System for FakeSystem {
    fn unit_alive(&self, unit: &str) -> bool {
        self.alive.contains(&unit)
    }
    fn boot_time(&self) -> Option<f64> {
        self.boot
    }
}

pub(super) fn new_job(store: &Store, unit: &str) -> String {
    store
        .new_record("pool sync", "hs pool sync", unit, "cli", "alice", "", "")
        .unwrap()
}

pub(super) fn read_file(store: &Store, id: &str) -> String {
    fs::read_to_string(store.dir.join(format!("{id}.json"))).unwrap()
}
