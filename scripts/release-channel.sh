#!/usr/bin/env bash
# help: show the update channel, the version installed and what the next hs update would install (reads the refs already fetched)
# help.de: den Update-Kanal, die installierte Version und was das nächste hs update installieren würde (liest die schon geholten Refs)
# args: --show
# Machine-readable (hs sys release show): key<TAB>value lines; nothing is fetched, nothing is changed.
#   channel   the setting updateChannel (stable|beta|edge)
#   installed the installed version (git describe) or the short revision
#   offer     one line per channel: offer<TAB><channel><TAB><ref or -><TAB><state>
#   ref       what `hs update` installs on the current channel (a tag, origin/develop, or - when there is no release tag yet)
#   state     none | unknown | current | kept | update (lib/update-channel.sh uc_state)
#   signed    yes | no | - (a tag is checked against the release keys; a branch and "none" have no signature)
# Test knobs: HS_REPO, HS_STATE_DIR, HS_SETTINGS_DIR.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/update-channel.sh"

[ "${1:-}" = "--show" ] || { echo "usage: release-channel.sh --show" >&2; exit 1; }
repo=${HS_REPO:-/etc/nixos}
owner=$(stat -c %U "$repo" 2>/dev/null || echo root)
if [ "$(id -u)" = 0 ] && [ "$owner" != root ]; then UC_OWNER=$owner; fi

channel=$(uc_channel)
installed=$(_uc_git "$repo" describe --tags --always 2>/dev/null || true)
printf 'channel\t%s\ninstalled\t%s\n' "$channel" "${installed:--}"
tail_lines=""
for c in stable beta edge; do
  IFS=$'\t' read -r kind ref _ < <(uc_target "$repo" "$c")
  st=$(uc_state "$repo" "$kind" "$ref")
  printf 'offer\t%s\t%s\t%s\n' "$c" "$ref" "$st"
  if [ "$c" = "$channel" ]; then
    signed=-
    if [ "$kind" = tag ]; then
      if ( uc_verify "$repo" "$ref" ) >/dev/null 2>&1; then signed=yes; else signed=no; fi
    fi
    tail_lines=$(printf 'ref\t%s\nstate\t%s\nsigned\t%s' "$ref" "$st" "$signed")
  fi
done
printf '%s\n' "$tail_lines"
