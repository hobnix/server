#!/usr/bin/env bash
# Warns when a change to the core adds no changelog entry (CONTRIBUTING.md, docs/changelog/README.md). Never blocks: CI turns exit 3 into a warning.
#   scripts/dev/changelog-check.sh <base-rev>
# Looks at `git diff --name-only <base-rev> HEAD`: a change in scripts/, web/src/, config/, configuration.nix or modules/ (not tests/,
# not scripts/dev/) without a new docs/changelog/*.toml gives a warning and exit 3; otherwise ok and exit 0. Usage error: exit 1.
set -uo pipefail
here=$(dirname "$0"); . "$here/../lib/ui.sh"
base=${1:-}
[ -n "$base" ] || { say "usage: changelog-check.sh <base-rev>"; exit 1; }
changed=$(git diff --name-only "$base" HEAD 2>/dev/null) || { warn "$(t "Cannot compare with '%s'." "$base")"; exit 3; }
touched=$(grep -E '^(scripts/|web/src/|config/|configuration\.nix$|modules/)' <<<"$changed" | grep -vE '^(tests/|scripts/dev/)' || true)
if [ -z "$touched" ]; then ok "$(t 'No user-visible files changed.')"; exit 0; fi
added=$(git diff --name-only --diff-filter=A "$base" HEAD -- docs/changelog | grep -E '\.toml$' || true)
if [ -n "$added" ]; then ok "$(t 'A changelog entry is added.')"; exit 0; fi
warn "$(t 'This change touches scripts, web, config or modules but adds no docs/changelog entry.')"
note "$(t 'If users see the change, add docs/changelog/<date>-<slug>.toml (CONTRIBUTING.md).')"
exit 3
