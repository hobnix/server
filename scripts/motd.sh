#!/usr/bin/env bash
# help: three status lines for the login: problems, last backup, system (hs motd; shown by itself at SSH login)
# help.de: drei Statuszeilen für die Anmeldung: Probleme, letztes Backup, System (hs motd; erscheint beim SSH-Login von selbst)
# args: [--force]
# Reads only the state files the timers keep (health.state, backup.state), so it needs no root and is
# instant. Silent when machine.toml says `loginMessage = false` (/etc/hs/login-message = off), unless --force.
# HS_STATE_DIR, HS_HEALTH_STATE, HS_BACKUP_STATE, HS_LOGIN_MESSAGE, HS_LOCKED_MARKER, HS_ROOT_DF: tests.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/secret.sh"
state=${HS_STATE_DIR:-/var/lib/hs}
health=${HS_HEALTH_STATE:-$state/health.state}
backup=${HS_BACKUP_STATE:-$state/backup.state}
. "$here/lib/setting.sh"
switch=${HS_LOGIN_MESSAGE:-}   # a file holding "off" (tests); else the runtime setting loginMessage
locked=${HS_LOCKED_MARKER:-/run/hs/storage-locked}

force=false
case "${1:-}" in
  --force) force=true ;;
  "") ;;
  *) say "usage: hs motd [--force]"; exit 1 ;;
esac
if [ -n "$switch" ]; then shown=$(cat "$switch" 2>/dev/null || echo on)
else shown=$(setting_get loginMessage 2>/dev/null || echo true); fi
$force || { [ "$shown" != off ] && [ "$shown" != false ]; } || exit 0

ago() {   # ago <epoch>
  local d=$(( $(date +%s) - $1 ))
  [ "$d" -ge 0 ] || d=0
  if [ "$d" -lt 3600 ]; then t '%s min ago' "$((d / 60))"
  elif [ "$d" -lt 172800 ]; then t '%s h ago' "$((d / 3600))"
  else t '%s days ago' "$((d / 86400))"; fi
}

# 0. encrypted storage that nobody has unlocked: this is what matters most
if [ -e "$locked" ]; then
  warn "The encrypted storage is locked. Unlock it: hs unlock"
elif vault_configured && ! vault_is_open; then
  warn "The vault is closed: run hs unlock"   # closed on purpose (hs vault close): the marker is not there
fi

# 1. problems (the keys the health check listed the last time they changed)
if [ -r "$health" ]; then
  n=$(tail -n +2 "$health" | grep -c . || true)
  if [ "${n:-0}" -gt 0 ]; then
    warn "$(t '%s problem(s). Look at them: hs health' "$n")"
  else
    ok "No problems found."
  fi
else
  note "The health check has not run yet."
fi

# 2. backup
if [ "$(secret_state "$state/restic-password")" = missing ] && [ ! -r "$backup" ]; then
  note "No backup yet. Set it up: hs backup init <device>"
else
  last=$(sed -n 's/^last_ok=//p' "$backup" 2>/dev/null | tail -n1)
  st=$(sed -n 's/^status=//p' "$backup" 2>/dev/null | tail -n1)
  if [ -z "$last" ]; then
    note "No successful backup yet: hs backup now"
  elif [ "$st" != ok ] && [ -n "$st" ]; then
    warn "$(t 'Last successful backup %s, the last try did not work: hs backup status' "$(ago "$last")")"
  elif [ $(( $(date +%s) - last )) -gt 172800 ]; then
    warn "$(t 'Last successful backup %s: hs backup status' "$(ago "$last")")"
  else
    ok "$(t 'Last successful backup %s' "$(ago "$last")")"
  fi
fi

# 3. system: uptime and the system disk
up=$(awk '{ s = int($1); d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60); o = ""
  if (d) o = d " d "
  if (d || h) o = o h " h "
  print o m " min" }' "${HS_PROC_UPTIME:-/proc/uptime}" 2>/dev/null || true)   # units the same in every language
used=$(df -P / 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }')
note "$(t 'Up %s, system disk %s%% full. All commands: hs help' "${up:-?}" "${used:-?}")"
