#!/usr/bin/env bash
# help: apply the config in /etc/nixos without pulling (nixos-rebuild switch)
# help.de: wendet die Konfiguration in /etc/nixos an, ohne vorher zu holen (nixos-rebuild switch)
# args: [--verbose]
# Started by `hs update`, a failed switch or a failed check afterwards (sshd running, Incus answering) goes back to the previous
# generation: on a terminal after asking, with --yes or without a terminal (timer, job) at once, with a push message.
# After a good switch the Git revision is written to /var/lib/hs/last-rebuild-rev (the health check compares it with the checkout).
# After that the health check (health-check.sh --keys) is watched for up to 5 minutes: a problem that was not there before the switch
# (config:* ignored) rolls back the same way; it ends early as soon as nothing new is left. --no-rollback skips both checks.
# Test knobs: HS_REPO, HS_STATE_DIR, HS_CURRENT_SYSTEM, HS_POST_WAIT, HS_POST_TRIES, HS_UPDATE_YES, HS_NO_ROLLBACK,
# HS_HEALTH_CHECK (script), HS_HEALTH_WINDOW (seconds, default 300), HS_HEALTH_INTERVAL (default 30).
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"
. "$(dirname "$0")/lib/locked.sh"
. "$(dirname "$0")/lib/stamp.sh"
. "$(dirname "$0")/lib/machine.sh"
. "$(dirname "$0")/lib/capability.sh"

refuse_if_locked   # before any build (also with --verbose / nixos-rebuild options)

# A background job (systemd-run, started from the web interface) has no login environment: without NIX_PATH nix-build cannot find
# <nixpkgs/nixos> and the build ends with "file 'nixpkgs/nixos' was not found in the Nix search path". NixOS writes the value it
# gives every login shell into /etc/set-environment; take it from there.
if [ -z "${NIX_PATH:-}" ] && [ -r /etc/set-environment ]; then
  NIX_PATH=$(sed -n '/^export NIX_PATH=/{s/^export NIX_PATH="\(.*\)"$/\1/p;q}' /etc/set-environment)
  [ -n "$NIX_PATH" ] && export NIX_PATH
fi

# started by hs update (it sent "update started"): say how it ended, also when it stopped early
if [ -n "${HS_UPDATE_NOTIFY:-}" ]; then
  update_done() {
    local rc=$?
    if [ "$rc" -eq 0 ]; then
      bash "$(dirname "$0")/notify.sh" --category ok "$(hostname): update finished" "\`hs update\` is done." low || true
    else
      bash "$(dirname "$0")/notify.sh" --category problem "$(hostname): update failed" "\`hs update\` stopped with an error (exit $rc). Look at the console." high || true
    fi
  }
  trap update_done EXIT
fi

# --verbose (or any other option of nixos-rebuild): show everything it prints
if [ $# -gt 0 ]; then
  [ "$1" != --verbose ] || shift
  nixos-rebuild switch "$@"   # no exec: the EXIT trap above must still run
  move_bulk_disks
  write_stamp
  exit
fi

# A typo or a wrong type in machine.toml: one readable line instead of a Nix trace
config_check() {
  [ -f "$(machine_file)" ] || return 0
  HS_QUIET_OK=1 bash "$(dirname "$0")/machine-sync.sh" check || exit 1
}

# Since the `gpu` setting exists, a graphics driver is only installed when machine.toml says so.
# A server that had the NVIDIA driver before would lose it silently: say so before the rebuild.
gpu_check() {
  local v found="" f=/etc/nixos/machine.nix
  if [ -f "$(machine_file)" ]; then
    machine_has gpu && return 0
  else
    [ -r "$f" ] || return 0
    # an old machine.nix: a gpu line that is not a comment
    grep -v '^[[:space:]]*#' "$f" | grep -Eq '(^|[^A-Za-z0-9_])gpu[[:space:]]*=' && return 0
  fi
  for v in /sys/class/drm/card*/device/vendor; do
    [ -r "$v" ] || continue
    case "$(cat "$v")" in 0x10de) found="nvidia" ;; esac
  done
  [ -n "$found" ] || return 0
  warn "An NVIDIA card is built in, but machine.toml has no gpu line. The driver would be removed."
  note "Add to /etc/nixos/machine.toml:   gpu = \"nvidia\"    (several: gpu = [\"nvidia\", \"intel\"])"
  if [ -t 0 ] && [ -t 1 ]; then confirm "Rebuild anyway?" || exit 1; fi
}

# What the rebuild switched to: the Git revision of the checkout, for the health check ("running system = checkout?").
write_stamp() {
  local repo=${HS_REPO:-/etc/nixos} dir=${HS_STATE_DIR:-/var/lib/hs} rev dirty=0
  [ -e "$repo/.git" ] || return 0
  rev=$(git -c safe.directory="$repo" -C "$repo" rev-parse HEAD 2>/dev/null) || return 0
  [ -z "$(git -c safe.directory="$repo" -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=1
  mkdir -p "$dir" 2>/dev/null || return 0
  { printf 'rev=%s\ndirty=%s\nmachine=%s\ntime=%s\n' "$rev" "$dirty" "$(config_fingerprint "$repo")" "$(date +%s)" > "$dir/last-rebuild-rev.tmp" \
    && mv "$dir/last-rebuild-rev.tmp" "$dir/last-rebuild-rev"; } 2>/dev/null || true
}

# ── Safety net of `hs update` ──
cur_system=${HS_CURRENT_SYSTEM:-/run/current-system}
rollback_enabled() { [ -n "${HS_UPDATE_NOTIFY:-}" ] && [ -z "${HS_NO_ROLLBACK:-}" ]; }
asks_first() { [ -z "${HS_UPDATE_YES:-}" ] && { { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ]; } || [ -n "${HS_GUIDED_TTY:-}" ]; }; }
push() { bash "$(dirname "$0")/notify.sh" --category problem "$(hostname): $1" "$2" high || true; }
failed_units() { { systemctl --failed --plain --no-legend 2>/dev/null || true; } | awk '{print $1}' | sort; }

# post_check: the system still does what it must to be reachable (sshd running, Incus answering). Prints what is wrong
# and returns 1; tries a few times, services may still be coming up. Units that failed since the switch only get a warning.
post_check_once() {
  local bad=""
  if systemctl cat sshd.service >/dev/null 2>&1 && ! systemctl is-active --quiet sshd.service; then bad="${bad}sshd is not running; "; fi
  if systemctl cat incus.service >/dev/null 2>&1 && ! timeout 30 incus list -c n -f csv >/dev/null 2>&1 </dev/null; then bad="${bad}Incus does not answer; "; fi
  [ -z "$bad" ] || { echo "${bad%; }"; return 1; }
}
post_check() {
  local i out="" tries=${HS_POST_TRIES:-4}
  for ((i = 1; i <= tries; i++)); do
    out=$(post_check_once) && return 0
    [ "$i" -eq "$tries" ] || sleep "${HS_POST_WAIT:-5}"
  done
  echo "$out"; return 1
}

# health_keys: the keys of the problems the health check finds now (sorted; config:* left out, it follows the stamp that is written later)
health_keys() { { bash "${HS_HEALTH_CHECK:-$(dirname "$0")/health-check.sh}" --keys 2>/dev/null || true; } | { grep -v '^config:' || true; } | sort -u; }
# health_new <keys before>: watches for up to HS_HEALTH_WINDOW seconds and ends as soon as nothing new is left. Prints the new keys that
# are still there at the end and returns 1; returns 0 when clean. Never while the storage is locked (everything is down then).
health_new() {
  local before=$1 end new="" interval=${HS_HEALTH_INTERVAL:-30}
  end=$(( $(date +%s) + ${HS_HEALTH_WINDOW:-300} ))
  while :; do
    storage_locked && return 0
    new=$(comm -13 <(printf '%s\n' "$before") <(health_keys) | sed '/^$/d' | tr '\n' ' ')
    [ -n "$new" ] || return 0
    [ "$(date +%s)" -lt "$end" ] || break
    sleep "$interval"
  done
  echo "${new% }"; return 1
}

rollback_now() {   # rollback_now <what went wrong>
  warn "$1"
  if asks_first && ! confirm "Go back to the previous generation now?"; then
    note "Later: sudo nixos-rebuild switch --rollback"
    push "update not rolled back" "$1. The system was left as it is."
    return 1
  fi
  if SPIN_TAIL=30 spin "Going back to the previous generation" nixos-rebuild switch --rollback; then
    move_bulk_disks back
    ok "Rolled back to the previous generation"
    push "update rolled back" "$1. The previous generation is running again."
  else
    warn "The rollback failed too. By hand: sudo nixos-rebuild switch --rollback"
    push "ROLLBACK FAILED" "$1, and going back failed as well. Log in and run: sudo nixos-rebuild switch --rollback"
  fi
  return 0
}

# The disks of the bulk array moved from /mnt/bulk/data-NN to /var/lib/hs/disks. bulk-mount.service is never restarted by a
# switch, so a running server moves them here: bulk-mount.sh mounts every disk at its new place, swaps the branches of /bulk under the running mount and lets
# go of the old mount points. Idempotent; at boot nothing is mounted yet, so nothing is moved. `back` does the reverse (after a rollback to the old scripts).
move_bulk_disks() {
  [ "$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)" = snapraid ] || return 0
  local d
  if [ "${1:-}" = back ]; then
    for d in /var/lib/hs/disks/data-* /var/lib/hs/disks/parity-*; do
      mountpoint -q "$d" 2>/dev/null || continue
      HS_DISKS_ROOT=/mnt/bulk bash "$(dirname "$0")/bulk-mount.sh" >/dev/null 2>&1 || warn "The disks of the array could not be moved back to /mnt/bulk (hs pool bulk)"
      return 0
    done
    return 0
  fi
  for d in /mnt/bulk/data-* /mnt/bulk/parity-*; do
    mountpoint -q "$d" 2>/dev/null || continue
    [ ! -e "${HS_STATE_DIR:-/var/lib/hs}/detached/${d##*/}" ] || continue   # a detached disk lives there on purpose
    bash "$(dirname "$0")/bulk-mount.sh" >/dev/null 2>&1 || warn "The disks of the array could not be moved to /var/lib/hs/disks (hs pool bulk)"
    return 0
  done
}

generation() { { readlink /nix/var/nix/profiles/system 2>/dev/null || true; } | sed -n 's/^system-\([0-9]*\)-link$/\1/p'; }

config_check
gpu_check

step "Rebuild"
before=$(readlink -f "$cur_system")
gen_before=$(generation)
failed_before=""
health_before=""
if rollback_enabled; then failed_before=$(failed_units); health_before=$(health_keys); fi
# the build prints hundreds of lines; they matter only when it fails
SPIN_TAIL=60 spin "Building the system and switching to it (after big changes: many minutes)" nixos-rebuild switch || {
  if rollback_enabled; then
    # a failed build changes nothing; a switch that broke half way has already moved the running system
    if [ "$(readlink -f "$cur_system")" != "$before" ]; then
      rollback_now "The switch failed after it had started" || true
    else
      note "Nothing was switched: the system runs as before."
    fi
  fi
  next_step "hs rebuild --verbose"
  exit 1
}
after=$(readlink -f "$cur_system")
move_bulk_disks

if rollback_enabled; then
  if ! why=$(post_check); then
    rollback_now "After the switch: $why" || true
    exit 1
  fi
  if ! storage_locked; then
    note "Watching the health check for new problems (up to 5 minutes)"
    if ! new_problems=$(health_new "$health_before"); then
      rollback_now "$(t 'After the switch the health check reports new problems: %s' "$new_problems")" || true
      exit 1
    fi
  fi
  new_failed=$(comm -13 <(printf '%s\n' "$failed_before") <(failed_units) | sed '/^$/d' | tr '\n' ' ')
  [ -z "$new_failed" ] || warn "$(t 'Units that failed since the switch: %s' "$new_failed")"
fi
write_stamp

if [ "$before" = "$after" ]; then
  ok "Nothing to change: the system already matches the configuration"
else
  if [ -z "$gen_before" ]; then ok "$(t 'Now running generation %s' "$(generation)")"
  else ok "$(t 'Now running generation %s (before: %s)' "$(generation)" "$gen_before")"; fi
  note "Back to the previous one, if something broke: sudo nixos-rebuild switch --rollback"
fi

# services that did not come up are reported by nixos-rebuild as warnings
problems=$(grep -E '^warning: the following units failed|^(Failed|failed) to (start|restart|reload)' <<<"$spin_out" || true)
if [ -n "$problems" ]; then
  warn "Some services had trouble:"
  sed 's/^/      /' <<<"$problems"
  note "Details: systemctl --failed"
fi

# a new kernel (or NVIDIA driver built for it) is only used after a restart
if [ "$(readlink -f /run/booted-system/kernel 2>/dev/null)" != "$(readlink -f /run/current-system/kernel 2>/dev/null)" ]; then
  warn "A new kernel is installed. It is used after a restart: sudo reboot"
fi

# the documentation pages follow the repo (the Docs page of the web interface, capability docs: webUi = true and webDocs not false)
if capability_on docs; then
  bash "$(dirname "$0")/docs-build.sh" --quiet >/dev/null 2>&1 || note "The documentation pages could not be rebuilt: hs docs build"
fi

elapsed_line
