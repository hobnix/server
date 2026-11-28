//! The error texts of the job store: one line each, worded like job-record.py.

use crate::Error;

pub(super) fn failed(message: impl Into<String>) -> Error {
    Error::Failed(message.into())
}

/// The OS text of an I/O error without Rust's " (os error N)" (what Python calls strerror).
pub(super) fn strerror(error: &std::io::Error) -> String {
    let text = error.to_string();
    match text.rsplit_once(" (os error ") {
        Some((message, _)) => message.to_string(),
        None => text,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strerror_drops_only_the_last_error_number() {
        let from_the_system = std::io::Error::from_raw_os_error(2);
        assert!(!strerror(&from_the_system).contains("os error"));
        let own = std::io::Error::other("a (os error 1) b (os error 2)");
        assert_eq!(strerror(&own), "a (os error 1) b");
        assert_eq!(strerror(&std::io::Error::other("plain")), "plain");
    }
}
