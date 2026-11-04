# shellcheck shell=bash
# Who did what (hobnix/server#167, docs/adr/0005-events.md): the dispatcher (scripts/lib/hs.sh) calls audit_record after a command whose
# registry row has the flag `changes`. One event audit.ok or audit.failed in the event log, written by event_emit (best effort, never fails).
#   audit_record <typed words> <exit code> <flags>
# Logged: who (actor), the words typed to find the command (`share add photos`), the exit code. NEVER the arguments after those words
# (they may carry a password or a key); rows with the flag nohelp (timers, udev and event hooks) and the event log itself are not logged.
# Actor: HS_ACTOR (the web interface sets the signed-in user), else HS_CALLER timer|job|web (ui counts as web), else SUDO_USER, else USER, else cli.
# Test knobs: HS_AUDIT_FORCE=1 (log although HS_CALLER=test), HS_AUDIT_OFF=1 (log nothing).

audit_actor() {
  local a=${HS_ACTOR:-}
  if [ -z "$a" ]; then
    case "${HS_CALLER:-}" in
      timer|job|web) a=$HS_CALLER ;;
      ui) a=web ;;
      *) a=${SUDO_USER:-${USER:-cli}} ;;
    esac
  fi
  a=$(printf '%s' "$a" | tr -c 'A-Za-z0-9._@-' '_')
  printf '%s' "${a:0:64}"
}

audit_record() {
  local words=$1 rc=$2 flags=${3:-} here actor kind
  [ -z "${HS_AUDIT_OFF:-}" ] || return 0
  [ "${HS_CALLER:-}" != test ] || [ -n "${HS_AUDIT_FORCE:-}" ] || return 0
  case ",$flags," in *,nohelp,*) return 0 ;; esac
  case "$words" in event*|audit*|"sys event"*|"sys audit"*) return 0 ;; esac
  here=${BASH_SOURCE[0]%/*}
  # shellcheck source=scripts/lib/event.sh
  . "$here/event.sh"
  actor=$(audit_actor)
  kind=audit.ok; [ "$rc" = 0 ] || kind=audit.failed
  event_emit "$kind" "$words" "" --payload "{\"actor\":\"$actor\",\"exit\":$rc}" || true
  return 0
}
