//! One-line structured log events for stderr; journald reads the `<P>` prefix.

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Error,
    Warn,
    Info,
    Debug,
}

impl Level {
    /// Syslog priority.
    pub fn priority(self) -> u8 {
        match self {
            Level::Error => 3,
            Level::Warn => 4,
            Level::Info => 6,
            Level::Debug => 7,
        }
    }

    pub fn parse(s: &str) -> Option<Level> {
        match s.trim().to_ascii_lowercase().as_str() {
            "error" => Some(Level::Error),
            "warn" => Some(Level::Warn),
            "info" => Some(Level::Info),
            "debug" => Some(Level::Debug),
            _ => None,
        }
    }

    /// Maximum level from `HOBNIX_LOG` (default info).
    pub fn from_env() -> Level {
        std::env::var("HOBNIX_LOG")
            .ok()
            .and_then(|v| Level::parse(&v))
            .unwrap_or(Level::Info)
    }
}

/// True when an event of `level` should be written under maximum `max`.
pub fn enabled(level: Level, max: Level) -> bool {
    level <= max
}

const SENSITIVE: [&str; 6] = ["password", "passwd", "secret", "token", "key", "passphrase"];

fn is_sensitive(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    SENSITIVE.iter().any(|s| k.contains(s))
}

fn quote(value: &str) -> String {
    let needs = value.is_empty()
        || value
            .chars()
            .any(|c| c.is_whitespace() || c == '"' || c == '=' || c == '\\');
    if !needs {
        return value.to_string();
    }
    let mut out = String::from("\"");
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// `<P>event key=value ...`, always a single line.
pub fn format(level: Level, event: &str, fields: &[(&str, &str)]) -> String {
    let mut line = format!(
        "<{}>{}",
        level.priority(),
        event.replace(['\n', '\r', ' ', '=', '\t', '"'], "_")
    );
    for (k, v) in fields {
        line.push(' ');
        line.push_str(&k.replace(['\n', '\r', '\t', ' ', '=', '"'], "_"));
        line.push('=');
        if is_sensitive(k) {
            line.push_str("***");
        } else {
            line.push_str(&quote(v));
        }
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn priorities() {
        assert_eq!(Level::Error.priority(), 3);
        assert_eq!(Level::Warn.priority(), 4);
        assert_eq!(Level::Info.priority(), 6);
        assert_eq!(Level::Debug.priority(), 7);
    }

    #[test]
    fn enabled_levels() {
        assert!(enabled(Level::Error, Level::Info));
        assert!(enabled(Level::Info, Level::Info));
        assert!(!enabled(Level::Debug, Level::Info));
    }

    #[test]
    fn parse_levels() {
        assert_eq!(Level::parse("DEBUG"), Some(Level::Debug));
        assert_eq!(Level::parse("nope"), None);
    }

    #[test]
    fn plain_line() {
        assert_eq!(
            format(Level::Info, "start", &[("pool", "tank")]),
            "<6>start pool=tank"
        );
    }

    #[test]
    fn quoting() {
        let l = format(
            Level::Warn,
            "e",
            &[("a", "x y"), ("b", "q\"r"), ("c", "k=v")],
        );
        assert_eq!(l, "<4>e a=\"x y\" b=\"q\\\"r\" c=\"k=v\"");
    }

    #[test]
    fn one_line() {
        let l = format(Level::Error, "e", &[("m", "a\nb")]);
        assert!(!l.contains('\n'));
        assert!(l.contains("a\\nb"));
    }

    #[test]
    fn redaction() {
        let l = format(
            Level::Info,
            "e",
            &[
                ("Password", "p1"),
                ("api_token", "t"),
                ("SSH_KEY", "k"),
                ("name", "n"),
            ],
        );
        assert_eq!(l, "<6>e Password=*** api_token=*** SSH_KEY=*** name=n");
    }
}
