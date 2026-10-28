# shellcheck shell=bash
# Routing of push messages (used by scripts/notify.sh;  routing").
# Sourced, not run. No curl here: sending stays in lib/ntfy.sh (ntfy_send), which the proxyserver repo copies; this file
# is NOT mirrored there.
#
#   route_rank <priority>        min=1 low=2 default=3 high=4 urgent=5 (anything else = default)
#   route_quiet_now              true while the setting quietHours ("HH:MM-HH:MM", server time, may cross midnight) holds
#   route_hold <title> <message> <priority> <category>   keep a message for the end of the quiet window
#   route_held_count             how many are waiting
#   route_flush_text             print title TAB body of ONE digest of everything held (nothing when empty)
#   route_held_clear             forget what was held
#   route_second_wanted <priority>   true when notifyUrlSecond should get a message of this priority
# Rules: high and urgent are never held. The journal line is written by notify.sh when the message happens, held or not.
# Test knobs: HS_HELD_DIR, HS_QUIET_HOURS (overrides the setting), HS_NOW_HM (HH:MM instead of the clock),
# HS_NOTIFY_URL_SECOND, HS_NOTIFY_SECOND_MIN, HS_HELD_MAX.

route_rank() {
  case "$1" in
    min) echo 1 ;; low) echo 2 ;; high) echo 4 ;; urgent) echo 5 ;; *) echo 3 ;;
  esac
}

_route_dir() { echo "${HS_HELD_DIR:-${HS_STATE_DIR:-/var/lib/hs}/notify-held}"; }

_route_setting() {   # <key>: the value of a runtime setting, empty when unset
  if declare -F setting_get >/dev/null 2>&1; then setting_get "$1" 2>/dev/null || true; fi
}

# HH:MM -> minutes since midnight; nothing for anything else
_route_min() {
  [[ "$1" =~ ^([0-2][0-9]):([0-5][0-9])$ ]] || return 1
  local h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  [ "$h" -le 23 ] || return 1
  echo $(( h * 60 + m ))
}

route_quiet_now() {
  local spec=${HS_QUIET_HOURS-$(_route_setting quietHours)} from to now hm
  [[ "$spec" =~ ^([0-9:]+)-([0-9:]+)$ ]] || return 1
  from=$(_route_min "${BASH_REMATCH[1]}") || return 1
  to=$(_route_min "${BASH_REMATCH[2]}") || return 1
  [ "$from" -ne "$to" ] || return 1
  hm=${HS_NOW_HM:-$(date +%H:%M)}
  now=$(_route_min "$hm") || return 1
  if [ "$from" -lt "$to" ]; then
    [ "$now" -ge "$from" ] && [ "$now" -lt "$to" ]
  else
    [ "$now" -ge "$from" ] || [ "$now" -lt "$to" ]
  fi
}

route_hold() {   # title message priority category
  local d f
  d=$(_route_dir)
  mkdir -p "$d" 2>/dev/null || return 1
  f="$d/$(date +%s)-$$-$RANDOM.msg"
  { printf '%s\n%s\n%s\n%s\n' "$(date +%H:%M)" "$3" "$4" "$1"; printf '%s\n' "$2"; } > "$f" 2>/dev/null || return 1
  # a runaway source cannot fill the disk: keep the newest HS_HELD_MAX (50)
  ls -1 "$d"/*.msg 2>/dev/null | sort | head -n -"${HS_HELD_MAX:-50}" | while read -r old; do rm -f "$old"; done
  return 0
}

route_held_count() { ls -1 "$(_route_dir)"/*.msg 2>/dev/null | grep -c . || true; }

route_flush_text() {
  local d f n=0 hm prio title first body=""
  d=$(_route_dir)
  for f in $(ls -1 "$d"/*.msg 2>/dev/null | sort); do
    hm=$(sed -n 1p "$f"); prio=$(sed -n 2p "$f"); title=$(sed -n 4p "$f"); first=$(sed -n 5p "$f")
    first=${first//\*\*/}; first=${first//\`/}
    body+="- $hm $title: $first"$'\n'
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 0
  printf '%s messages from the quiet hours\t%s' "$n" "${body%$'\n'}"
}

route_held_clear() { rm -f "$(_route_dir)"/*.msg 2>/dev/null || true; }

route_second_wanted() {
  local min=${HS_NOTIFY_SECOND_MIN-$(_route_setting notifySecondMinPriority)}
  [ "$(route_rank "$1")" -ge "$(route_rank "${min:-high}")" ]
}
