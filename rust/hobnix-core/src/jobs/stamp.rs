//! The files beside a record: the stamps of the rate limit, removed with the lock file when a job ends.

use super::store::Store;
use super::timestamp::seconds_between;
use std::fs;
use std::path::PathBuf;
use std::time::SystemTime;

impl Store {
    pub(super) fn stamp_path(&self, id: &str, kind: &str) -> PathBuf {
        self.dir.join(format!("{id}.{kind}.stamp"))
    }

    /// True when the last write of this kind was less than `rate` seconds ago (mtime of the stamp file).
    pub(super) fn is_rate_limited(&self, id: &str, kind: &str) -> bool {
        match fs::metadata(self.stamp_path(id, kind)).and_then(|metadata| metadata.modified()) {
            Ok(written) => seconds_between(written, SystemTime::now()) < self.rate,
            Err(_) => false,
        }
    }

    pub(super) fn touch_stamp(&self, id: &str, kind: &str) {
        let _ = fs::File::create(self.stamp_path(id, kind));
    }

    pub(super) fn remove_stamps_and_lock(&self, id: &str) {
        for kind in ["step", "progress"] {
            let _ = fs::remove_file(self.stamp_path(id, kind));
        }
        let _ = fs::remove_file(self.lock_path(id));
    }
}
