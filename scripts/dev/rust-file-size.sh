#!/usr/bin/env bash
# File size limit for rust/ (docs/CODE-PRACTICES.md "Rust: size"): the lines of a .rs file before its `#[cfg(test)]` module (the whole
# file when it has none). Integration tests (rust/*/tests/) and build output are not counted. Developer tool and CI helper (job `rust`).
#   rust-file-size.sh check   every counted file has at most 400 lines (exit 1 otherwise)
#   rust-file-size.sh list    "<lines>\t<path>" for every counted file
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
root=${HS_RUST_SIZE_ROOT:-$repo}
limit=400

# Counting ends at the test module only: `#[cfg(test)]`, maybe more attributes, then `mod x {`. Any other item under `#[cfg(test)]`
# (`mod test_support;`, a test-only function) is counted like the rest of the file.
count() {
  awk '
    pending && /^#\[/ { n++; held++; next }
    pending && /^(pub(\([a-z ]+\))? )?mod [A-Za-z0-9_]+ \{/ { n -= held; exit }
    { pending = 0 }
    /^#\[cfg\(test\)\]/ { pending = 1; held = 0 }
    { n++; if (pending) held++ }
    END { print n + 0 }
  ' "$1"
}
files() {
  (cd "$root" && find rust -name '*.rs' -not -path '*/target/*' -not -path 'rust/*/tests/*' | LC_ALL=C sort)
}
list() { files | while read -r f; do printf '%s\t%s\n' "$(count "$root/$f")" "$f"; done; }

case "${1:-}" in
  list) list ;;
  check)
    sizes=$(list) || { echo "could not list the Rust files under $root: nothing was checked" >&2; exit 1; }
    [ -n "$sizes" ] || { echo "no Rust files found under $root/rust: nothing was checked" >&2; exit 1; }
    bad=0
    while IFS=$'\t' read -r n f; do
      # a file that could not be read has no count; tab is whitespace to `read`, so its path then arrives in n
      case $n in
        '' | *[!0-9]*) echo "could not count the lines of ${f:-$n}" >&2; bad=1; continue ;;
      esac
      if [ "$n" -gt "$limit" ]; then
        echo "$f: $n lines before its tests, the limit is $limit: split it" >&2
        bad=1
      fi
    done <<<"$sizes"
    [ "$bad" = 0 ] && echo "rust file sizes ok"
    exit "$bad" ;;
  *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
