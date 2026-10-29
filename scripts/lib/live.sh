# shellcheck shell=bash
# live_refresh <topic>...|--all : ask the live-state collector to read these topics again. Fire and forget: a no-op while the capability
# is off or the socket is missing, no output, always returns 0 (a change script must not break on it).
live_refresh() {
  [ -S "${HS_LIVE_SOCKET:-/run/redis-hobnix/redis.sock}" ] || return 0
  timeout 2 python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/live_state.py" refresh "$@" >/dev/null 2>&1 || true
  return 0
}
