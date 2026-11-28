//! What is inside the box, and the checks of its names.

use crate::Secret;
use serde_json::{Value, json};

/// What the other side gets (or hands over) inside the box. Debug is safe: the password is a [`Secret`].
#[derive(Debug)]
pub struct Inner {
    pub server: String,
    pub host: String,
    pub share: String,
    pub login: String,
    pub domain: String,
    pub password: Secret,
    pub hostkey: String,
}

impl Inner {
    pub fn to_json(&self) -> Value {
        json!({"server": self.server, "host": self.host, "share": self.share, "login": self.login,
               "domain": self.domain, "password": self.password.expose(), "hostkey": self.hostkey})
    }

    pub fn from_json(v: &Value) -> Option<Inner> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        Some(Inner {
            server: s("server").filter(|x| valid_name(x))?,
            host: s("host").filter(|x| valid_host(x))?,
            share: s("share").filter(|x| valid_share(x))?,
            login: s("login").filter(|x| valid_login(x))?,
            domain: s("domain").filter(|x| x.is_empty() || valid_login(x))?,
            password: Secret::new(s("password").filter(|x| !x.is_empty() && x.len() <= 256)?),
            hostkey: s("hostkey").unwrap_or_default(),
        })
    }
}

fn word_ok(s: &str, max: usize, extra: &str) -> bool {
    let mut it = s.chars();
    s.len() <= max
        && it.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && it.all(|c| c.is_ascii_alphanumeric() || extra.contains(c))
}

/// The host name of a server: lower case, digits and dashes, at most 20 (`^[a-z0-9][a-z0-9-]{0,19}$`).
pub fn valid_name(s: &str) -> bool {
    word_ok(s, 20, "-") && !s.chars().any(|c| c.is_ascii_uppercase())
}
pub fn valid_share(s: &str) -> bool {
    word_ok(s, 64, "._-")
}
pub fn valid_login(s: &str) -> bool {
    word_ok(s, 64, "._-")
}
pub fn valid_host(s: &str) -> bool {
    word_ok(s, 253, "._:-")
}
