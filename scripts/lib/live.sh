# shellcheck shell=bash
# live_refresh <topic>...|--all : say that these topics changed. Two things, both best effort: count the topics up in the state database
# (table `topics`, state-db.py topic-bump, docs/adr/0005-events.md rule 5: the web interface watches it in every liveState mode) and ask the
# live-state collector to read them again (only while the socket exists). No output, always returns 0 (a change script must not break on it).
# <topic>, @<group> (every topic of that change area and of `any`) or --all. Test knob HS_LIVE_LOG: append the arguments as one line to that file
# instead of doing either.
live_refresh() {
  if [ -n "${HS_LIVE_LOG:-}" ]; then printf '%s\n' "$*" >>"$HS_LIVE_LOG" 2>/dev/null || true; return 0; fi
  timeout 5 "${HS_PYTHON:-python3}" "$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)/state-db.py" topic-bump "$@" >/dev/null 2>&1 || true
  [ -S "${HS_LIVE_SOCKET:-/run/redis-hobnix/redis.sock}" ] || return 0
  timeout 2 python3 "$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)/live_state.py" refresh "$@" >/dev/null 2>&1 || true
  return 0
}
