---
paths:
  - "scripts/**/*.sh"
  - "packages/**/*.sh"
  - "capabilities/**/*.sh"
  - "tests/**/*.sh"
  - "vps/**/*.sh"
---

# Shell scripts: output and pipes

Loaded when you touch the files above (path-scoped rule). The root CLAUDE.md has the rules that always apply.

- `IFS=$'\t' read` skips an EMPTY tab-separated field (tab is whitespace) and shifts every later one left (a service tile without a description showed its icon name as the description). A machine-readable line that bash reads must have no empty field: use `-` as the placeholder and map it back in the reader (`hs services tiles`, the dashboard).

- Under `set -euo pipefail` never pipe a command that may print more than the limit into `head -n N`: `head` closes the pipe, the producer gets SIGPIPE (141), pipefail makes the pipeline fail and `set -e` ends the script right there (`hs update` stopped after the Update step with more than 12 new changes). Use the command's own limit (`git log -n 12`). tests/update-preview.sh checks this.

- scripts/lib/ui.sh is the one place for terminal output (step, ok, note, warn, fail, spin,
  ask, ask_secret, confirm, table, box); it falls back to plain text without gum or a
  terminal. `spin` draws its own gum-style spinner with the last SPIN_LINES (3) lines of the
  step's output trailing underneath (dimmed, colour codes and progress-bar redraws removed) and
  the elapsed time after 3 s; a long step (`SPIN_STREAM=1`: without gum, in a job, one progress line a minute) must therefore print progress lines (a count, the
  current path; throttle them with awk) so the user can see it is moving. Scripts the interface reads (manage-*.sh list and --dry-run modes, share-cache
  --state, unifi used/reserved) must keep their machine-readable lines unchanged.
