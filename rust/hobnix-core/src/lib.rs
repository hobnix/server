//! Service layer: typed inputs and results, no terminal output (docs/adr/0001-rust-strangler.md).

/// Version of this build of the Rust part.
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_not_empty() {
        assert!(!version().is_empty());
    }
}
