#!/usr/bin/env bash
# help: pull the latest config from Git into /etc/nixos and rebuild; goes back by itself if new problems show up (--no-rollback: off)
# help.de: holt die neueste Konfiguration aus Git nach /etc/nixos und baut neu; geht von selbst zurück, wenn neue Probleme auftreten (--no-rollback: aus)
# args: [--verbose] [--yes] [--stop-on-new] [--no-rollback] [--force]
# Safety net: when the switch fails half way, or sshd / Incus are not running after it, the previous generation is switched back
# (nixos-rebuild switch --rollback) and a push message says so. A terminal is asked first; --yes and callers without a terminal
# (timer, job) roll back at once. --no-rollback leaves a broken system as it is. A failed build changes nothing: no rollback needed.
# Afterwards the health check is watched for up to 5 minutes (rebuild.sh): a problem that was not there before the switch rolls back too.
# The check after the switch is a cheap subset of `hs smoke` (a full smoke run could roll back over an unrelated missing tool).
# New options in machine.toml.example are put into machine.toml (in their place, commented out) and listed; a person at a terminal is
# asked whether to rebuild now or stop to set them first. --yes rebuilds without asking, --stop-on-new stops without asking.
# Nothing new (the same Git revision as the last rebuild, a clean checkout, machine.toml and hardware-configuration.nix as they were, no new
# options): it says so and skips the rebuild (no push message either). --force rebuilds anyway; so does `hs rebuild`, which always builds.
# No terminal (a job, a timer) rebuilds as before. Test knobs: HS_STATE_DIR, HS_MACHINE_FILE, HS_MACHINE_EXAMPLE, HS_GUIDED_TTY.
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"
. "$(dirname "$0")/lib/locked.sh"
. "$(dirname "$0")/lib/stamp.sh"

ask_new=auto; pass=(); force=false
for a in "$@"; do
  case "$a" in --force) force=true ;; --yes) ask_new=no; export HS_UPDATE_YES=1 ;; --no-rollback) export HS_NO_ROLLBACK=1 ;; --stop-on-new) ask_new=stop ;; *) pass+=("$a") ;; esac
done
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

refuse_if_locked   # before any fetch or build

repo=${HS_REPO:-/etc/nixos}   # HS_REPO: tests
owner=$(stat -c %U "$repo")

# Run git as the repo owner (uses their GitHub key, avoids "dubious ownership").
# -H: with root's HOME git would abort on the unreadable /root/.gitconfig.
as_owner() { sudo -H -u "$owner" git -C "$repo" "$@"; }

steps 2   # Update, then Rebuild (rebuild.sh continues the count)
step "Update"
old=$(as_owner rev-parse HEAD)
# ConnectTimeout: a GitHub that cannot be reached fails in 20 s, not after the two minutes of ssh's own timeout (a web job looked hung)
spin "Fetching the latest configuration" sudo -H -u "$owner" git -C "$repo" -c core.sshCommand="ssh -o BatchMode=yes -o ConnectTimeout=20" pull --ff-only || {
  fail_fix "$(t "Could not fetch the configuration: GitHub not reachable, or local changes in %s that Git can't combine?" "$repo")" "git -C $repo status"
}
new=$(as_owner rev-parse HEAD)
rev_now=$new
if [ "$old" = "$new" ]; then
  ok "Already the latest configuration"
else
  count=$(as_owner rev-list --count "$old..$new")
  ok "$(t '%s new change(s):' "$count")"
  # git limits the lines itself: a `| head -n 12` closes the pipe early, git gets SIGPIPE and pipefail + set -e end
  # the whole update right here (it did, with more than 12 new changes)
  as_owner log --format='%s' -n 12 "$old..$new" | while IFS= read -r line; do note "$line"; done
  [ "$count" -le 12 ] || note "$(t '... and %s more' "$((count - 12))")"
  if [ -f "$repo/scripts/changes.sh" ]; then
    n=$(bash "$repo/scripts/changes.sh" --count --from "$old" 2>/dev/null) || n=0
    [[ $n =~ ^[0-9]+$ ]] || n=0
    [ "$n" -eq 0 ] || note "$(t '%s new entries in the changelog: hs changes' "$n")"
  fi
fi

# machine.nix -> machine.toml once (the old file is kept as machine.nix.migrated), then the options that are new in
# machine.toml.example are put into machine.toml in their place, commented out (nothing of yours is changed)
sync=$repo/scripts/machine-sync.sh
new=""
if [ -f "$sync" ]; then
  if [ ! -f "${HS_MACHINE_FILE:-$repo/machine.toml}" ] && [ -f "$repo/machine.nix" ]; then
    bash "$sync" migrate || warn "machine.nix was not converted: the rebuild uses it as it is. Look at: hs config migrate"
  fi
  new=$(bash "$sync" --list 2>/dev/null || true)
  HS_QUIET_OK=1 bash "$sync" sync || true
fi
if [ -n "$new" ] && [ "$ask_new" != no ]; then
  stop=false
  if [ "$ask_new" = stop ]; then stop=true
  elif interactive; then
    pick=$(choose "$(t '%s new option(s) in machine.toml. Rebuild now?' "$(wc -l <<<"$new" | tr -d ' ')")" \
      "$(t 'Rebuild now')" "$(t 'Stop here, so I can set them first')") || pick=stop
    [ "$pick" = "$(t 'Rebuild now')" ] || stop=true
  fi
  if $stop; then
    note "$(t 'Edit %s, then run: hs rebuild' "${HS_MACHINE_FILE:-$repo/machine.toml}")"
    bash "$(dirname "$0")/notify.sh" --category info "$(hostname): update stopped" "The new configuration is fetched. Set the new options in machine.toml, then run \`hs rebuild\`." low || true
    exit 0
  fi
fi

# Nothing to apply? The system was built from exactly this revision, the checkout is clean, machine.toml and the hardware file are as they were
# and no option is new: say so and stop (a push message "started" was not sent, so none is needed). --force and `hs rebuild` build anyway.
if ! $force && [ -z "$new" ] && [ "$(stamp_get rev)" = "$rev_now" ] && [ "$(stamp_get dirty)" = 0 ] &&
   [ "$(stamp_get machine)" = "$(config_fingerprint "$repo")" ] && [ -z "$(as_owner status --porcelain --untracked-files=no)" ]; then
  ok "$(t 'Nothing changed since the last rebuild (%s): the system is up to date, no rebuild needed.' "$(as_owner rev-parse --short HEAD)")"
  note "$(t 'To build anyway: hs update --force (or hs rebuild).')"
  exit 0
fi

# Notification channels (capability notifications): once the part is on, the channels derived from the old settings become files
# (nothing is lost: they keep referring to the settings). Quiet, and never a reason to stop the update.
if ( . "$(dirname "$0")/lib/capability.sh"; capability_on notifications ) 2>/dev/null; then
  bash "$(dirname "$0")/notify-channel.sh" migrate >/dev/null 2>&1 || true
fi

bash "$(dirname "$0")/notify.sh" --category start "$(hostname): update started" "\`hs update\` is running." low || true
[ "$old" = "$rev_now" ] || export HS_UPDATE_FROM=$old   # rebuild.sh counts the new changelog entries since then
export HS_UPDATE_NOTIFY=1   # rebuild.sh sends "update finished" / "update failed"

# this script itself may have changed: run the rebuild from the new copy
exec bash "$repo/scripts/rebuild.sh" ${pass[@]+"${pass[@]}"}
