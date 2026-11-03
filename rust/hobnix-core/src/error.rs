//! Typed errors and the exit-code map shared by every command.

use std::fmt;

/// Exit code: success.
pub const EXIT_OK: u8 = 0;
/// Exit code: the request was refused (bad input, not allowed).
pub const EXIT_REFUSED: u8 = 1;
/// Exit code: the thing asked for does not exist.
pub const EXIT_MISSING: u8 = 2;

/// What went wrong, in terms the caller can act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Refused(String),
    Missing(String),
    Failed(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    /// Process exit code for this error.
    pub fn exit_code(&self) -> u8 {
        match self {
            Error::Refused(_) => EXIT_REFUSED,
            Error::Missing(_) => EXIT_MISSING,
            Error::Failed(_) => 1,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Refused(m) | Error::Missing(m) | Error::Failed(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for Error {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_codes() {
        assert_eq!(EXIT_OK, 0);
        assert_eq!(Error::Refused("a".into()).exit_code(), 1);
        assert_eq!(Error::Missing("a".into()).exit_code(), 2);
        assert_eq!(Error::Failed("a".into()).exit_code(), 1);
    }

    #[test]
    fn display_is_message_only() {
        assert_eq!(Error::Missing("no disk".into()).to_string(), "no disk");
    }
}
