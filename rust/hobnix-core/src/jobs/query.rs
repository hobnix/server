//! Questions about records; nothing is written.

use super::failure::{failed, strerror};
use super::record::Record;
use super::store::{Store, record_id};
use crate::Result;
use std::fs;

impl Store {
    /// `find-unit`: the id of the newest queued/running record of a unit (with or without `.service`).
    pub fn find_unit(&self, unit: &str) -> Result<String> {
        let mut ids: Vec<String> = self
            .record_file_names()
            .unwrap_or_default()
            .iter()
            .filter_map(|name| record_id(name).map(str::to_string))
            .collect();
        ids.sort_by(|a, b| b.cmp(a));
        let bare = unit.strip_suffix(".service").unwrap_or(unit);
        let is_running_job_of_unit = |record: Record| {
            let recorded = record.unit.as_deref();
            (recorded == Some(unit) || recorded == Some(bare)) && record.is_active()
        };
        ids.into_iter()
            .find(|id| self.load(id).is_ok_and(is_running_job_of_unit))
            .ok_or_else(|| failed(format!("no running job record for {unit}")))
    }

    /// `cancelled`: true when the record says cancelled.
    pub fn is_cancelled(&self, id: &str) -> Result<bool> {
        Ok(self.load(id)?.state.as_deref() == Some("cancelled"))
    }

    /// `get`: the file as it is (after it was checked to be a record).
    pub fn get(&self, id: &str) -> Result<Vec<u8>> {
        self.load(id)?;
        fs::read(self.path_of(id)?)
            .map_err(|error| failed(format!("cannot read record {id}: {}", strerror(&error))))
    }
}

#[cfg(test)]
mod tests {
    use crate::jobs::test_support::{TemporaryDirectory, new_job, read_file};

    #[test]
    fn find_unit_picks_the_highest_id() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let first = new_job(&store, "hs-job-x-1");
        let mut later = first.clone();
        later.replace_range(..8, "29990101");
        let mut record = store.load(&first).unwrap();
        record.id = Some(later.clone());
        store.save(&record).unwrap();
        assert_eq!(store.find_unit("hs-job-x-1.service").unwrap(), later);
    }

    #[test]
    fn get_returns_the_file() {
        let temporary = TemporaryDirectory::new();
        let store = temporary.store();
        let id = new_job(&store, "u");
        assert_eq!(
            String::from_utf8(store.get(&id).unwrap()).unwrap(),
            read_file(&store, &id)
        );
    }
}
