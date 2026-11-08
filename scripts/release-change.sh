#!/usr/bin/env bash
# help: switch the update channel without asking anything: what would happen (plan), then do it (start)
# help.de: den Update-Kanal wechseln, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start channel <stable|beta|edge> [--confirm <channel>]
# System command (hs sys release plan|start): for the interface and tests. It never asks. The work is one setting (updateChannel); like `hs update`
# (docs/PLAN-channels.md) it checks the signature of the tag the new channel would install, says what the next update does, and asks for the
# channel name when the new channel is newer (a person typed it: --confirm). Nothing is fetched or installed here; a switch to an older channel
# keeps the installed version until the channel catches up (no downgrade).
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note|danger|command<TAB><line>,
#   confirm_name<TAB><channel> (only with a danger line), long<TAB>no.
# start: the same checks, then status<TAB>done.
# Test knobs: HS_REPO, HS_SETTINGS_DIR, HS_STATE_DIR.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/update-channel.sh"
. "$here/lib/effect.sh"

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; new=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: release-change.sh plan|start channel <stable|beta|edge> [--confirm <channel>]" >&2; exit 1 ;; esac
[ "$action" = channel ] || refuse "unknown action (channel)"
case "$new" in stable|beta|edge) ;; *) refuse "unknown channel (stable, beta or edge)" ;; esac
shift 3
confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) confirm=${2:-}; shift 2 || refuse "--confirm needs a value" ;;
    *) refuse "unknown option $1" ;;
  esac
done

repo=${HS_REPO:-/etc/nixos}
owner=$(stat -c %U "$repo" 2>/dev/null || echo root)
if [ "$(id -u)" = 0 ] && [ "$owner" != root ]; then UC_OWNER=$owner; fi

old=$(uc_channel)
[ "$new" != "$old" ] || refuse "The server is on the channel $new already."

IFS=$'\t' read -r kind ref label < <(uc_target "$repo" "$new")
if [ "$kind" = tag ]; then
  vrc=0
  vout=$(uc_verify "$repo" "$ref" 2>&1 || { printf '%s\n' "${UC_VERIFY_OUT:-}"; exit 1; }) || vrc=$?
  if [ "$vrc" -ne 0 ]; then
    refuse "The signature of $ref is not valid for a trusted release key: $(printf '%s\n' "$vout" | awk 'NF { print; exit }')"
  fi
fi
st=$(uc_state "$repo" "$kind" "$ref")
installed=$(_uc_git "$repo" describe --tags --always 2>/dev/null || echo "?")

danger=""
if [ "$(uc_rank "$new")" -gt "$(uc_rank "$old")" ]; then
  danger="The channel $new can break things: use it only on a server whose data may be lost."
fi

if [ "$verb" = start ]; then
  if [ -n "$danger" ] && [ "$confirm" != "$new" ]; then refuse "type the channel name to confirm: $new"; fi
  setting_set updateChannel "$new"
  printf 'status\tdone\n'
  exit 0
fi

printf 'status\tok\n'
printf 'heading\tswitch the update channel from %s to %s\n' "$old" "$new"
printf 'step\tset updateChannel to %s (nothing is installed by this step)\n' "$new"
case "$st" in
  none)    printf 'note\tThere is no release tag for %s yet: the next update follows the current branch as before.\n' "$new" ;;
  unknown) printf 'note\tThe checkout has not fetched %s yet: the next update looks for it.\n' "$ref" ;;
  current) printf 'note\tNo update is waiting: this server runs %s already (%s).\n' "$ref" "$installed" ;;
  kept)    printf 'note\tThe installed version %s stays: %s is older, so there is no downgrade. Updates continue when the channel catches up.\n' "$installed" "$ref" ;;
  update)  printf 'step\tthe next update installs %s (now %s)\n' "$label" "$installed" ;;
esac
if [ "$kind" = tag ]; then printf 'note\tThe signature of %s was checked against the release keys.\n' "$ref"; fi
if [ "$new" != stable ]; then printf 'note\tBeta and edge are never applied by themselves: the update waits until a person starts it.\n'; fi
if [ -n "$danger" ]; then
  printf 'danger\t%s\n' "$danger"
  printf 'confirm_name\t%s\n' "$new"
fi
printf 'note\t%s Nothing is rebuilt by this step.\n' "$(effect_now)"
printf 'command\ths config set updateChannel %s\n' "$new"
printf 'long\tno\n'
