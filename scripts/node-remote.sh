#!/usr/bin/env bash
# help: forced command for the key another server uses to look at this one (authorized_keys: restrict,command="/etc/nixos/scripts/node-remote.sh" ssh-ed25519 ...)
# help.de: erzwungener Befehl für den Schlüssel, mit dem ein anderer Server diesen ansieht (authorized_keys: restrict,command="/etc/nixos/scripts/node-remote.sh" ssh-ed25519 ...)
# Receiving side of `hs node status`. It reads $SSH_ORIGINAL_COMMAND and accepts EXACTLY the words below, nothing else
# (no arguments, no shell, no pattern). A word runs one fixed command and prints plain data. Anything else: exit 2 and a line in the journal.
#   status   the status document of this server (JSON, the same as `hs sys deck`; on an edge node `hs sys edge status`)
# To allow more, add a word here AND to NODE_WORDS in scripts/node.sh, each with a test; never a pattern.
# Test knobs: HS_DECK_FILE (default /run/hs-deck/deck.json), HS_DECK_STATUS (the script that makes the document).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/capability.sh"
word=${SSH_ORIGINAL_COMMAND:-}
log() { logger -t hs-node-remote -- "$*" 2>/dev/null || true; }
case "$word" in
  status)
    f=${HS_DECK_FILE:-/run/hs-deck/deck.json}
    # an edge node (capability edge-status) keeps the same file; without it the document is made on the spot by ITS script
    fresh=deck-status.sh; if capability_on edge-status; then fresh=edge-status.sh; fi
    if [ -s "$f" ]; then cat "$f"; else bash "${HS_DECK_STATUS:-$here/$fresh}"; fi ;;
  *)
    log "refused: $(printf '%s' "$word" | head -c 60 | tr -c '[:alnum:] ._-' '?')"
    echo "node-remote: not allowed (only: status)" >&2
    exit 2 ;;
esac
