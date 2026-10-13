/// Smoke-test entry point for the Burrow EPUB engine Rust backend.
///
/// Returns the crate version so Dart can verify the FFI bridge is wired up.
/// `frb(sync)` makes the generated Dart binding a plain `String engineVersion()`
/// (the version is a cheap constant, so there is no reason to hop isolates).
#[flutter_rust_bridge::frb(sync)]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_version_is_non_empty() {
        assert!(!engine_version().is_empty());
    }

    #[test]
    fn engine_version_matches_cargo_pkg_version() {
        assert_eq!(engine_version(), env!("CARGO_PKG_VERSION"));
    }
}
