#!/usr/bin/env bash
# The file size limit of rust/ (scripts/dev/rust-file-size.sh): counting stops at the test module, a file over 400 lines fails, a check
# that finds no files fails, integration tests and build output are not counted, and the real tree passes. No root, no cargo.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
R="bash $SCRIPTS/dev/rust-file-size.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/rust/a/src" "$T/rust/a/tests" "$T/rust/target/x"
lines() { local i; for ((i = 0; i < $1; i++)); do echo "// $i"; done; }
{ lines 10; echo '#[cfg(test)]'; echo 'mod tests {'; lines 900; } > "$T/rust/a/src/small.rs"
lines 400 > "$T/rust/a/src/big.rs"
lines 900 > "$T/rust/a/tests/integration.rs"
lines 900 > "$T/rust/target/x/gen.rs"
export HS_RUST_SIZE_ROOT=$T

check_eq "lines before the test module, integration tests and build output not counted" \
  "$(printf '400\trust/a/src/big.rs\n10\trust/a/src/small.rs')" "$($R list)"
check "a file of 400 lines passes" $R check
lines 401 > "$T/rust/a/src/big.rs"
if $R check >/dev/null 2>&1; then fail "a file over 400 lines passed"; else pass "a file over 400 lines fails"; fi
{ echo '#[cfg(test)]'; echo 'mod test_support;'; lines 400; } > "$T/rust/a/src/big.rs"
if $R check >/dev/null 2>&1; then fail "a test-only declaration ended the count"; else pass "a test-only declaration does not end the count"; fi
{ lines 5; echo '#[cfg(test)]'; echo '#[rustfmt::skip]'; echo 'pub(crate) mod tests {'; lines 900; } > "$T/rust/a/src/big.rs"
check_eq "an attribute between cfg(test) and the module belongs to the tests" "5" "$($R list | awk -F'\t' '$2 == "rust/a/src/big.rs" { print $1 }')"
mkdir -p "$T/empty/rust"
if HS_RUST_SIZE_ROOT=$T/empty $R check >/dev/null 2>&1; then fail "a tree without Rust files passed"; else pass "a tree without Rust files fails"; fi
if HS_RUST_SIZE_ROOT=$T/missing $R check >/dev/null 2>&1; then fail "a missing tree passed"; else pass "a missing tree fails"; fi
unset HS_RUST_SIZE_ROOT
check "the real tree passes" $R check
finish
