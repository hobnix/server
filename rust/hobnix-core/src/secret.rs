//! A value that must never reach a log line or a terminal by accident.

use std::fmt;

pub struct Secret(String);

impl Secret {
    pub fn new(value: impl Into<String>) -> Self {
        Secret(value.into())
    }

    /// The only way to read the value; call it where the secret is really used.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("***")
    }
}

impl fmt::Display for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("***")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn never_printed() {
        let s = Secret::new("hunter2");
        assert_eq!(format!("{}", s), "***");
        assert_eq!(format!("{:?}", s), "***");
        assert_eq!(s.expose(), "hunter2");
    }
}
