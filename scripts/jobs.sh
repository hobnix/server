#!/usr/bin/env bash
# help: scheduled jobs (hs-* timers): when they run next, when they ran last, and whether that worked
# help.de: geplante Aufgaben (hs-*-Timer): wann sie als Nächstes laufen, wann zuletzt, und ob es geklappt hat
# args: [--list | --running | --show <unit> | --log <unit> [N] | tail <unit> [N] | stop <unit> | <unit> [--follow]]
set -euo pipefail
. "$(dirname "$0")/lib/ui.sh"

# --list: one line per timer, tab separated:
#   unit (the service, e.g. hs-backup.service)  description  next run  last run  result (ok | failed | never)
# <unit>: the last lines of its journal. Needs no root. Used by the interface (tab Jobs, overview tiles).

prop() {   # prop <unit> <property> : the value, or empty
  systemctl show "$1" -p "$2" --value 2>/dev/null || true
}

# nosudo: a job's journal without the lines sudo writes into it each time a script calls `sudo -u adminuser ...`
# (the "COMMAND=" line and the pam_unix session open/close pair); they say nothing about the job.
nosudo() {
  grep -Ev 'pam_unix\(sudo[^)]*\):| : (TTY=[^ ]+ ; )?PWD=[^ ]+ ; USER=[^ ]+ ; COMMAND=' || true
}

short() {  # "Mon 2026-10-05 04:00:00 UTC" -> "05.10. 04:00"; empty or n/a -> "-"
  local t=$1
  if [ -z "$t" ] || [ "$t" = "n/a" ]; then echo "-"; return; fi
  date -d "$t" '+%d.%m. %H:%M' 2>/dev/null || echo "$t"
}

list() {
  local timer unit next last result st
  while read -r timer; do
    [ -n "$timer" ] || continue
    unit=${timer%.timer}.service
    next=$(prop "$timer" NextElapseUSecRealtime)
    last=$(prop "$unit" ExecMainExitTimestamp)
    result=$(prop "$unit" Result)
    st=$(prop "$unit" ExecMainStatus)
    if [ -z "$last" ] || [ "$last" = "n/a" ]; then
      result=never
    elif [ "$result" = success ] && [ "${st:-0}" = 0 ]; then
      result=ok
    else
      result=failed
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$unit" "$(prop "$unit" Description)" "$(short "$next")" "$(short "$last")" "$result"
  done < <(systemctl list-timers --all --no-legend --no-pager 2>/dev/null | tr -s ' ' '\n' | grep -E '^hs-.*\.timer$' | sort -u || true)
}

# --running: jobs started by long commands (hs-job-*.service): unit, description, started
running() {
  local unit
  while read -r unit; do
    [ -n "$unit" ] || continue
    printf '%s\t%s\t%s\n' "$unit" "$(prop "$unit" Description)" "$(short "$(prop "$unit" ActiveEnterTimestamp)")"
  done < <(systemctl list-units 'hs-job-*.service' --state=active,activating --no-legend --no-pager 2>/dev/null | awk '{ print $1 }' || true)
}

# hs job follow [<unit>]: a readable view of one job. Header (what, state, since when), then the journal as it
# comes; when the unit has finished, one closing line (ok or failed, exit status, how long it took) and the
# exit status of this command follows the job's. Ctrl-C only stops watching. Without a unit: the running job.
clock() {   # clock <seconds> -> m:ss or h:mm:ss
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60)); else printf '%d:%02d' $((s / 60)) $((s % 60)); fi
}
epoch() {   # epoch <systemd timestamp> -> seconds, or empty
  { [ -n "$1" ] && [ "$1" != n/a ] && date -d "$1" +%s 2>/dev/null; } || true
}
follow() {   # follow <unit>
  local unit=$1 load desc active start_ts t0 t1 res st tmp jpid off size what="" rc=0
  case "$unit" in *.service|*.timer|*.scope) ;; *) unit=$unit.service ;; esac
  load=$(prop "$unit" LoadState)
  desc=$(prop "$unit" Description)
  active=$(prop "$unit" ActiveState)
  start_ts=$(prop "$unit" ActiveEnterTimestamp)
  t0=$(epoch "$start_ts")

  steps 1
  step "${desc:-$unit}"
  note "$unit"
  case "$active" in
    active|activating|reloading) what=$(t 'running since %s' "$(short "$start_ts")") ;;
    failed)   what=$(t 'failed') ;;
    inactive) what=$(t 'not running (last start %s)' "$(short "$start_ts")") ;;
    *)        what=$(t 'not loaded: only the journal is left') ;;
  esac
  note "$what"
  echo

  tmp=$(mktemp)
  journalctl -fu "$unit" -n 40 --no-pager -o short-iso >"$tmp" 2>/dev/null </dev/null &
  jpid=$!
  trap 'kill "$jpid" 2>/dev/null; rm -f "$tmp"; echo; note "$(t "Stopped watching. The job keeps running: hs job follow %s" "$unit")"; exit 130' INT TERM
  off=0
  while :; do
    size=$(wc -c <"$tmp")
    if [ "$size" -gt "$off" ]; then tail -c +$((off + 1)) "$tmp" | nosudo | trail; off=$size; fi
    case "$(prop "$unit" ActiveState)" in active|activating|reloading) ;; *) break ;; esac
    sleep "${HS_FOLLOW_EVERY:-1}"
  done
  sleep "${HS_FOLLOW_EVERY:-1}"        # the last lines of the journal arrive a moment after the unit stops
  size=$(wc -c <"$tmp")
  if [ "$size" -gt "$off" ]; then tail -c +$((off + 1)) "$tmp" | nosudo | trail; fi
  kill "$jpid" 2>/dev/null || true
  wait "$jpid" 2>/dev/null || true
  rm -f "$tmp"
  trap - INT TERM

  echo
  if [ "$load" = not-found ] && [ "$size" -eq 0 ]; then fail "$(t "No job called '%s'." "$unit")"; fi
  res=$(prop "$unit" Result); st=$(prop "$unit" ExecMainStatus)
  t1=$(epoch "$(prop "$unit" InactiveEnterTimestamp)"); [ -n "$t1" ] || t1=$(date +%s)
  what=""
  if [ -n "$t0" ] && [ "$t1" -ge "$t0" ]; then what=$(t ' after %s' "$(clock $((t1 - t0)))"); fi
  if [ "$load" = not-found ]; then
    note "The unit is gone, so its result is not known."
  elif [ "$res" = success ] && [ "${st:-0}" = 0 ]; then
    ok "$(t 'Finished successfully (exit status %s)%s' "${st:-0}" "$what")"
  else
    fail "$(t 'Failed: %s, exit status %s%s' "${res:-unknown}" "${st:-?}" "$what")"
  fi
  return $rc
}

# tail <unit> [N]: what the interface shows of a running or finished job, plain, never asks. Lines after the first N
# lines of the journal, so it can be called again with `next`:
#   state<TAB>running|ok|failed|unknown     (unknown: the unit is gone and left no journal)
#   exit<TAB><status>                       (only when finished)
#   line<TAB><text>                         (one per new journal line)
#   next<TAB><count>                        (pass it as N the next time)
tail_job() {
  local unit=$1 from=${2:-0} load active res st all total state
  case "$unit" in *.service|*.timer|*.scope) ;; *) unit=$unit.service ;; esac
  [[ "$from" =~ ^[0-9]+$ ]] || from=0
  load=$(prop "$unit" LoadState); active=$(prop "$unit" ActiveState)
  all=$(journalctl -u "$unit" -o cat --no-pager 2>/dev/null </dev/null | nosudo || true)
  total=$(printf '%s' "$all" | grep -c '' || true)
  case "$active" in
    active|activating|reloading) state=running ;;
    *)
      res=$(prop "$unit" Result); st=$(prop "$unit" ExecMainStatus)
      if [ "$load" = not-found ] && [ "${total:-0}" -eq 0 ]; then state=unknown
      elif [ "$res" = success ] && [ "${st:-0}" = 0 ]; then state=ok
      else state=failed; fi ;;
  esac
  printf 'state\t%s\n' "$state"
  [ "$state" = running ] || [ "$state" = unknown ] || printf 'exit\t%s\n' "${st:-0}"
  if [ "${total:-0}" -gt "$from" ]; then printf '%s\n' "$all" | tail -n +$((from + 1)) | awk '{ print "line\t" $0 }'; fi
  printf 'next\t%s\n' "${total:-0}"
}

# show <unit>: the facts of one job for the interface (key<TAB>value, plain, never asks). Only hs-* units.
#   unit, description, state (running|ok|failed|never|unknown), exit (when it has run), started, last, next (the timer), command
valid_unit() { [[ "$1" =~ ^hs-[A-Za-z0-9@._-]+\.service$ ]]; }
show_unit() {
  local unit=$1 load active res st last exe next
  case "$unit" in *.service) ;; *) unit=$unit.service ;; esac
  valid_unit "$unit" || { echo "not a job unit: $1" >&2; return 1; }
  load=$(prop "$unit" LoadState); active=$(prop "$unit" ActiveState)
  res=$(prop "$unit" Result); st=$(prop "$unit" ExecMainStatus); last=$(prop "$unit" ExecMainExitTimestamp)
  printf 'unit\t%s\n' "$unit"
  printf 'description\t%s\n' "$(prop "$unit" Description)"
  case "$active" in
    active|activating|reloading) printf 'state\trunning\n' ;;
    *)
      if [ "$load" = not-found ]; then printf 'state\tunknown\n'
      elif [ -z "$last" ] || [ "$last" = n/a ]; then printf 'state\tnever\n'
      elif [ "$res" = success ] && [ "${st:-0}" = 0 ]; then printf 'state\tok\nexit\t0\n'
      else printf 'state\tfailed\nexit\t%s\n' "${st:-?}"; fi ;;
  esac
  printf 'started\t%s\n' "$(short "$(prop "$unit" ActiveEnterTimestamp)")"
  printf 'last\t%s\n' "$(short "$last")"
  next=$(prop "${unit%.service}.timer" NextElapseUSecRealtime)
  printf 'next\t%s\n' "$(short "$next")"
  exe=$(prop "$unit" ExecStart | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//' | head -n 1 || true)
  printf 'command\t%s\n' "$exe"
}
# log <unit> [N]: the last N journal lines (default 200) of one job, plain (the interface's log view)
log_unit() {
  local unit=$1 n=${2:-200}
  case "$unit" in *.service) ;; *) unit=$unit.service ;; esac
  valid_unit "$unit" || { echo "not a job unit: $1" >&2; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] || n=200
  journalctl -u "$unit" -n "$n" --no-pager -o short-iso 2>/dev/null </dev/null | nosudo | grep -v '^-- ' || true
}

pick_running() {   # the one running job, or ask
  local lines=() choice
  mapfile -t lines < <(running | awk -F'\t' '{ printf "%s  %s\n", $1, $2 }')
  [ ${#lines[@]} -gt 0 ] || fail_fix "No job is running." "hs job list"
  if [ ${#lines[@]} -eq 1 ]; then echo "${lines[0]%% *}"; return; fi
  [ -t 0 ] && [ -t 1 ] || fail_fix "Several jobs are running: name one." "hs job follow <unit>"
  choice=$(choose "Which job?" "${lines[@]}") || exit 0
  echo "${choice%% *}"
}

case "${1:-}" in
  --list) list ;;
  "")  # a person gets a table, the interface and pipes the raw lines
       if [ -t 1 ]; then
         rows=$(list)
         failed=$(awk -F'\t' '$5 == "failed"' <<<"$rows" | grep -c . || true)
         if [ "$failed" -eq 0 ]; then status_line "Failed jobs" "None" ok; else status_line "Failed jobs" "$failed" warn; fi
         { thead 'Job' 'What' 'Next' 'Last' 'Result'; [ -z "$rows" ] || printf '%s\n' "$rows"; } | table
         running=$(running)
         if [ -n "$running" ]; then
           echo; line "Running now:"
           while IFS=$'\t' read -r u d since; do note "$(t '%s since %s (%s)' "$d" "$since" "$u")"; done <<<"$running"
         fi
       else list; fi ;;
  --running) running ;;
  --show) [ $# -ge 2 ] || exit 1; show_unit "$2" ;;
  --log) [ $# -ge 2 ] || exit 1; log_unit "$2" "${3:-200}" ;;
  tail) [ $# -ge 2 ] || exit 1; tail_job "$2" "${3:-0}" ;;
  stop) [ $# -ge 2 ] || { say "usage: hs job stop <unit>"; exit 1; }; systemctl stop "$2"; ok "$(t 'Stopped %s' "$2")" ;;
  -h|--help) say "usage: hs job list | running | log <unit> | follow <unit> | stop <unit>"; exit 0 ;;
  --follow) follow "$(pick_running)" ;;
  *) if [ "${2:-}" = --follow ]; then follow "$1"; else journalctl -u "$1" -n 40 --no-pager | nosudo | trail; fi ;;
esac
