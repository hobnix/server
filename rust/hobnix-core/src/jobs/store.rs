//! The record files: where they are, how one is read, and how it is changed atomically under its lock.

use super::failure::{failed, strerror};
use super::job_id::valid_id;
use super::record::Record;
use crate::Result;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

/// The id a file of this name is the record of. Exactly as job-record.py: `.JSON` is not a record.
pub(super) fn record_id(file_name: &str) -> Option<&str> {
    file_name.strip_suffix(".json")
}

/// Atomic write: temp file in the same directory, fsync, mode 0644, rename.
fn replace_file(path: &Path, temporary: &Path, record: &Record) -> std::io::Result<()> {
    let mut text = serde_json::to_string_pretty(record).map_err(std::io::Error::other)?;
    text.push('\n');
    let mut file = fs::File::create(temporary)?;
    file.write_all(text.as_bytes())?;
    file.flush()?;
    file.sync_all()?;
    drop(file);
    set_mode(temporary, 0o644)?;
    fs::rename(temporary, path)
}

/// The directory of records and its rate limit.
#[derive(Debug)]
pub struct Store {
    pub dir: PathBuf,
    /// Seconds between two step (or progress) writes of one job (`HS_JOB_RATE`, default 1).
    pub rate: f64,
}

impl Store {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Store {
            dir: dir.into(),
            rate: 1.0,
        }
    }

    pub(super) fn path_of(&self, id: &str) -> Result<PathBuf> {
        if !valid_id(id) {
            return Err(failed("bad job id"));
        }
        Ok(self.dir.join(format!("{id}.json")))
    }

    pub(super) fn lock_path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.lock"))
    }

    pub(super) fn ensure_dir(&self) -> Result<()> {
        let directory = &self.dir;
        fs::create_dir_all(directory)
            .and_then(|()| set_mode(directory, 0o755))
            .map_err(|error| {
                failed(format!(
                    "cannot create {}: {}",
                    directory.display(),
                    strerror(&error)
                ))
            })
    }

    /// The names of the record files; None when the directory cannot be read.
    pub(super) fn record_file_names(&self) -> Option<Vec<String>> {
        let entries = fs::read_dir(&self.dir).ok()?;
        Some(
            entries
                .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
                .filter(|name| record_id(name).is_some())
                .collect(),
        )
    }

    pub fn load(&self, id: &str) -> Result<Record> {
        let path = self.path_of(id)?;
        let bytes = fs::read(&path)
            .map_err(|error| failed(format!("cannot read record {id}: {}", strerror(&error))))?;
        let not_json = || failed(format!("record {id} is not valid JSON"));
        let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| not_json())?;
        if !value.is_object() {
            return Err(failed(format!("record {id} is not an object")));
        }
        // mirrored difference: a field of the wrong type is "not valid JSON" here; Python carries it along
        serde_json::from_value(value).map_err(|_| not_json())
    }

    /// Write one record, see `replace_file`.
    pub(super) fn save(&self, record: &Record) -> Result<()> {
        // mirrored: the file name comes from the id inside the record, not from the id asked for
        let path = self.path_of(record.id.as_deref().unwrap_or(""))?;
        let mut temporary = path.clone().into_os_string();
        temporary.push(format!(".{}.tmp", std::process::id()));
        let temporary = PathBuf::from(temporary);
        replace_file(&path, &temporary, record).map_err(|error| {
            let _ = fs::remove_file(&temporary);
            failed(format!("cannot write record: {}", strerror(&error)))
        })
    }

    /// Run `work` under an exclusive lock `<id>.lock`.
    /// mirrored: the lock file is made from the id as given, before it is checked.
    pub(super) fn locked<T>(&self, id: &str, work: impl FnOnce() -> Result<T>) -> Result<T> {
        let mut options = fs::OpenOptions::new();
        options.create(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o644);
        }
        let cannot_lock =
            |error: std::io::Error| failed(format!("cannot lock record: {}", strerror(&error)));
        let file = options.open(self.lock_path(id)).map_err(cannot_lock)?;
        file.lock().map_err(cannot_lock)?;
        work()
    }

    /// Read-modify-write of one record under its lock; nothing is written when `change` refuses.
    pub(super) fn update(
        &self,
        id: &str,
        change: impl FnOnce(&mut Record) -> Result<()>,
    ) -> Result<()> {
        self.locked(id, || {
            let mut record = self.load(id)?;
            change(&mut record)?;
            self.save(&record)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::jobs::test_support::TemporaryDirectory;

    #[test]
    fn errors_are_one_line_messages() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        assert_eq!(store.load("nope").unwrap_err().to_string(), "bad job id");
        let id = "20240101-120000-gone-abcd";
        assert!(
            store
                .run(id)
                .unwrap_err()
                .to_string()
                .starts_with("cannot lock record: ")
        );
        fs::create_dir_all(&store.dir).unwrap();
        #[cfg(unix)]
        assert_eq!(
            store.load(id).unwrap_err().to_string(),
            format!("cannot read record {id}: No such file or directory")
        );
        fs::write(store.dir.join(format!("{id}.json")), "{oops").unwrap();
        assert_eq!(
            store.load(id).unwrap_err().to_string(),
            format!("record {id} is not valid JSON")
        );
        fs::write(store.dir.join(format!("{id}.json")), "[1]").unwrap();
        assert_eq!(
            store.load(id).unwrap_err().to_string(),
            format!("record {id} is not an object")
        );
        assert!(store.get(id).is_err());
    }

    #[test]
    fn only_lower_case_json_files_are_records() {
        assert_eq!(record_id("a.json"), Some("a"));
        assert_eq!(record_id(".json"), Some(""));
        assert_eq!(record_id("a.JSON"), None);
        assert_eq!(record_id("a.json.7.tmp"), None);
        assert_eq!(record_id("json"), None);
    }
}
