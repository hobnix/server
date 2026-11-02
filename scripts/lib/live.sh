# shellcheck shell=bash
# live_refresh <topic>...|--all : ask the live-state collector to read these topics again. Fire and forget: a no-op while the capability
# is off or the socket is missing, no output, always returns 0 (a change script must not break on it).
# <topic>, @<group> (every topic of that change area and of `any`) or --all. Test knob HS_LIVE_LOG: append the arguments as one line to that file
# instead of talking to the socket.
live_refresh() {
  if [ -n "${HS_LIVE_LOG:-}" ]; then printf '%s\n' "$*" >>"$HS_LIVE_LOG" 2>/dev/null || true; return 0; fi
  [ -S "${HS_LIVE_SOCKET:-/run/redis-hobnix/redis.sock}" ] || return 0
  timeout 2 python3 "$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)/live_state.py" refresh "$@" >/dev/null 2>&1 || true
  return 0
}
