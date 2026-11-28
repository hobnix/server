//! Job store: one JSON record per job in a directory (docs/adr/0004-job-record.md, strangler step #137).
//!
//! The contract is scripts/job-record.py, byte for byte: the same file names, the same JSON layout, the same
//! messages. Where that program does something that looks accidental it is mirrored on purpose (marked "mirrored").
//! The two things that touch the machine, `systemctl is-active` and the boot time, sit behind [`System`] so tests use fakes.

mod create;
mod failure;
mod job_id;
mod query;
mod question;
mod reconcile;
mod record;
mod report;
mod retention;
mod shlex;
mod stamp;
mod store;
mod system;
#[cfg(test)]
mod test_support;
mod timestamp;
mod transitions;

pub use create::{KINDS, NewJob, SOURCES};
pub use job_id::valid_id;
pub use question::{ASK_KINDS, Question};
pub use reconcile::Reconciled;
pub use record::{Cancel, ErrorInfo, Progress, Record, Step, Waiting};
pub use retention::{KEEP_COUNT, KEEP_DAYS};
pub use shlex::shlex_split;
pub use store::Store;
pub use system::{RealSystem, System};
pub use timestamp::{format_iso, parse_iso};
