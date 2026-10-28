# shellcheck shell=bash
# Notification channels. Sourced, not run. NO curl here: a provider
# (scripts/notify/<provider>.sh) talks to the service; this file only stores channels and runs the providers.
#
# A channel is one file /var/lib/hs/notify-channels/<name>.conf (0600 in a 0700 directory: root only), key=value per line: provider,
# enabled (yes|no), minprio (min|low|default|high|urgent), quiet (respect|ignore), categories (the message classes it carries, from
# alarm,status,heartbeat,digest; default alarm,status,digest) and the provider's own settings. A value `@setting:<key>` is read from the
# runtime settings when the channel is loaded. While the directory has no `.migrated` marker, the channels `main` (notifyUrl) and `second`
# (notifyUrlSecond, notifySecondMinPriority) are DERIVED from the old settings, so an upgrade changes nothing. The channel `heartbeat`
# (heartbeatUrl, class heartbeat only) is derived as long as no file heartbeat.conf exists, marker or not.
#
#   chan_names                 every channel name, `main` first, then alphabetical
#   chan_source <name>         file | derived (nothing and exit 1 when unknown)
#   chan_load_text <name> <text>  the same from text (to check a channel before it is written)
#   chan_load <name>           fills the associative array CH (references resolved); exit 1 when unknown
#   chan_conf <name>           the unresolved text of the channel (what a file would hold)
#   chan_write <name>          key=value lines on stdin -> the file (atomic)
#   chan_migrate               write the derived channels as files and the marker (no-op once migrated)
#   chan_remove <name>
#   chan_provider_ok <p>       the provider script exists
#   chan_class <category>      the message class of a notify category: alarm (alarm lock problem), heartbeat, status (the rest)
#   chan_carries <class>       true when the loaded channel (CH) carries that class
#   chan_has_outside_alarm     true when an enabled channel outside this server carries alarm
#   chan_need_root "$0" "$@"   run the script again through sudo when the channel directory exists but this caller cannot read it
#   chan_run <provider> <sub> [args]   run a provider with CH_<key> from the loaded CH in its environment, timeout HS_NOTIFY_TIMEOUT (20)
# Test knobs: HS_NOTIFY_CHANNELS_DIR, HS_NOTIFY_PROVIDERS, HS_NOTIFY_URL, HS_NOTIFY_URL_SECOND, HS_NOTIFY_SECOND_MIN, HS_STATE_DIR.

. "$(dirname "${BASH_SOURCE[0]}")/setting.sh"

chan_dir() { echo "${HS_NOTIFY_CHANNELS_DIR:-${HS_STATE_DIR:-/var/lib/hs}/notify-channels}"; }
chan_providers_dir() { echo "${HS_NOTIFY_PROVIDERS:-$(dirname "${BASH_SOURCE[0]}")/../notify}"; }
chan_valid_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; }
chan_provider_ok() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]] && [ -f "$(chan_providers_dir)/$1.sh" ]; }

# a runtime setting as the old notify.sh read it (the test knobs win; an empty knob means "not set")
_chan_setting() {
  local v
  case "$1" in
    notifyUrl) printf '%s' "${HS_NOTIFY_URL-$(setting_get notifyUrl 2>/dev/null || true)}" ;;
    notifyUrlSecond) printf '%s' "${HS_NOTIFY_URL_SECOND-$(setting_get notifyUrlSecond 2>/dev/null || true)}" ;;
    notifySecondMinPriority)
      v=${HS_NOTIFY_SECOND_MIN-$(setting_get notifySecondMinPriority 2>/dev/null || true)}
      printf '%s' "${v:-high}" ;;
    heartbeatUrl) printf '%s' "${HS_HEARTBEAT_URL-$(setting_get heartbeatUrl 2>/dev/null || true)}" ;;
    *) printf '%s' "$(setting_get "$1" 2>/dev/null || true)" ;;
  esac
}

_chan_derived_conf() {   # <main|second>: the conf text, nothing when that old setting is empty
  case "$1" in
    main)
      [ -n "$(_chan_setting notifyUrl)" ] || return 0
      printf 'provider=ntfy\nenabled=yes\nminprio=min\nquiet=respect\ncategories=alarm,status,digest\nurl=@setting:notifyUrl\n' ;;
    second)
      [ -n "$(_chan_setting notifyUrlSecond)" ] || return 0
      printf 'provider=ntfy\nenabled=yes\nminprio=@setting:notifySecondMinPriority\nquiet=respect\ncategories=alarm,status,digest\nurl=@setting:notifyUrlSecond\n' ;;
    heartbeat)
      [ -n "$(_chan_setting heartbeatUrl)" ] || return 0
      printf 'provider=ntfy\nenabled=yes\nminprio=min\nquiet=ignore\ncategories=heartbeat\nurl=@setting:heartbeatUrl\n' ;;
  esac
  return 0
}

chan_migrated() { [ -e "$(chan_dir)/.migrated" ]; }

chan_names() {
  local d f n
  d=$(chan_dir)
  {
    for f in "$d"/*.conf; do
      [ -e "$f" ] || continue
      basename "$f" .conf
    done
    for n in main second heartbeat; do
      # the heartbeat does not wait for the migration: it is derived while there is no file of it
      if [ "$n" != heartbeat ] && chan_migrated; then continue; fi
      if [ ! -e "$d/$n.conf" ] && [ -n "$(_chan_derived_conf "$n")" ]; then echo "$n"; fi
    done
  } | sort -u | awk '$0 == "main" { print "0 " $0; next } { print "1 " $0 }' | sort | cut -d' ' -f2
  return 0
}

chan_source() {
  local d; d=$(chan_dir)
  if [ -e "$d/$1.conf" ]; then echo file; return 0; fi
  if { [ "$1" = heartbeat ] || ! chan_migrated; } && [ -n "$(_chan_derived_conf "$1" 2>/dev/null)" ]; then echo derived; return 0; fi
  return 1
}

chan_conf() {
  case "$(chan_source "$1" || true)" in
    file) cat "$(chan_dir)/$1.conf" ;;
    derived) _chan_derived_conf "$1" ;;
    *) return 1 ;;
  esac
}

# chan_load_text <name> <conf text>: CH[key]=value (references resolved), CH[name]. chan_load <name>: the same for a stored channel
# (exit 1 when unknown).
chan_load_text() {
  local line k v
  declare -gA CH=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ""|\#*) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    [[ "$k" =~ ^[a-z][a-zA-Z0-9_]*$ ]] || continue
    case "$v" in @setting:*) v=$(_chan_setting "${v#@setting:}") ;; esac
    CH[$k]=$v
  done <<<"$2"
  CH[name]=$1
  : "${CH[provider]:=ntfy}" "${CH[enabled]:=yes}" "${CH[minprio]:=min}" "${CH[quiet]:=respect}" "${CH[categories]:=alarm,status,digest}"
  return 0
}

chan_class() {   # <notify category> -> alarm | status | heartbeat
  case "$1" in alarm|lock|problem) echo alarm ;; heartbeat) echo heartbeat ;; *) echo status ;; esac
}

chan_carries() { case ",${CH[categories]:-}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

chan_load() {
  local conf
  conf=$(chan_conf "$1") || return 1
  chan_load_text "$1" "$conf"
}

chan_write() {   # chan_write <name>  (conf text on stdin)
  local d f
  d=$(chan_dir); f="$d/$1.conf"
  ( umask 077; mkdir -p "$d" && chmod 700 "$d" && cat > "$f.new" ) && mv "$f.new" "$f"
}

chan_remove() { rm -f "$(chan_dir)/$1.conf"; }

chan_migrate() {
  local d n
  d=$(chan_dir)
  chan_migrated && return 0
  ( umask 077; mkdir -p "$d" && chmod 700 "$d" ) || return 1
  for n in main second heartbeat; do
    [ -e "$d/$n.conf" ] && continue
    [ -n "$(_chan_derived_conf "$n")" ] || continue
    _chan_derived_conf "$n" | chan_write "$n" || return 1
  done
  ( umask 077; : > "$d/.migrated" )
}

# chan_run <provider> <sub> [args...]: the provider script with the loaded channel's settings as CH_<key>
# (the environment, never argv). CHAN_CATEGORY is the message category (default info).
chan_run() {
  local p=$1 k envs=()
  shift
  for k in "${!CH[@]}"; do envs+=("CH_$k=${CH[$k]}"); done
  envs+=("CH_CATEGORY=${CHAN_CATEGORY:-info}")
  if command -v timeout >/dev/null 2>&1; then
    env "${envs[@]}" timeout "${HS_NOTIFY_TIMEOUT:-20}" bash "$(chan_providers_dir)/$p.sh" "$@"
  else
    env "${envs[@]}" bash "$(chan_providers_dir)/$p.sh" "$@"
  fi
}

# ── What happened to the last send (shown by the web interface; never a secret) ──
# $(chan_dir)/.results   name TAB time TAB ok|failed TAB short reason     the last send per channel
# $(chan_dir)/.told      key TAB time TAB channels (comma separated)       who got the last message about a health problem
# Both live next to the channel files (root only); a write that fails is ignored: a send never fails because of its bookkeeping.

# chan_scrub_reason <text>: one short line without an address or a long token (a topic or a token is a secret)
chan_scrub_reason() {
  local r
  r=$(printf '%s\n' "$1" | head -n1 | tr '\t\r' '  ' | sed -E 's#[^ ]*://[^ ]*#<address>#g; s#[A-Za-z0-9_./=+-]{24,}#...#g' | cut -c1-100)
  printf '%s' "${r:--}"
}

# _chan_upsert <file> <key> <rest of the line>: replace the line of <key> (the first field) or add it
_chan_upsert() {
  local f=$1 d; d=$(dirname "$1")
  ( umask 077
    mkdir -p "$d" && chmod 700 "$d" 2>/dev/null
    { [ ! -r "$f" ] || awk -F'\t' -v k="$2" '$1 != k' "$f"; printf '%s\t%s\n' "$2" "$3"; } > "$f.new" && mv "$f.new" "$f"
  ) 2>/dev/null || true
}

# chan_result_set <channel> ok|failed [reason]
chan_result_set() {
  _chan_upsert "$(chan_dir)/.results" "$1" "${HS_NOW:-$(date +%s)}"$'\t'"$2"$'\t'"$(chan_scrub_reason "${3:-}")"
}

# chan_result_get <channel>: time TAB ok|failed TAB reason, or - TAB - TAB - while nothing was sent
chan_result_get() {
  local f; f="$(chan_dir)/.results"
  if [ -r "$f" ] && awk -F'\t' -v k="$1" '$1 == k { print $2 "\t" $3 "\t" ($4 == "" ? "-" : $4); f = 1 } END { exit !f }' "$f"; then return 0; fi
  printf -- '-\t-\t-\n'
}

# chan_told_set <keys, comma separated> <channels, space separated>: those channels took the last message about those problems
chan_told_set() {
  local k chans=${2// /,}
  [ -n "$chans" ] || return 0
  IFS=, read -r -a _ks <<<"$1"
  for k in "${_ks[@]}"; do [ -z "$k" ] || _chan_upsert "$(chan_dir)/.told" "$k" "${HS_NOW:-$(date +%s)}"$'\t'"$chans"; done
  return 0
}

# chan_told_get <key>: the channels (comma separated) or -
chan_told_get() {
  local f; f="$(chan_dir)/.told"
  if [ -r "$f" ] && awk -F'\t' -v k="$1" '$1 == k && $3 != "" { print $3; f = 1 } END { exit !f }' "$f"; then return 0; fi
  echo -
}

# chan_told_prune: keep only the keys on stdin (a problem that is gone is forgotten)
chan_told_prune() {
  local f keep; f="$(chan_dir)/.told"
  keep=$(cat)
  [ -w "$f" ] || return 0
  awk -F'\t' 'NR == FNR { p[$0] = 1; next } ($1 in p)' <(printf '%s\n' "$keep") "$f" > "$f.new" 2>/dev/null && mv "$f.new" "$f" || rm -f "$f.new"
}

# chan_has_outside_alarm: an enabled channel that carries alarm and is served from outside this server (the provider's `where`).
# A subshell, so the caller's CH is not touched.
chan_has_outside_alarm() (
  local n
  for n in $(chan_names); do
    chan_load "$n" || continue
    [ "${CH[enabled]}" = yes ] || continue
    chan_carries alarm || continue
    chan_provider_ok "${CH[provider]}" || continue
    [ "$(chan_run "${CH[provider]}" where 2>/dev/null || true)" = outside ] && return 0
  done
  return 1
)

# chan_need_root <script> [args...]: the channel directory is 0700 root. A caller that cannot read it asks sudo to run the same script.
# (Without the directory only the derived channels exist and their settings are read as before.)
chan_need_root() {
  local d; d=$(chan_dir)
  [ -d "$d" ] && [ ! -r "$d" ] || return 0
  [ "$(id -u)" -ne 0 ] || return 0
  [ -z "${HS_NOTIFY_NO_SUDO:-}" ] || return 0
  command -v sudo >/dev/null 2>&1 || return 0
  exec sudo -- bash "$@"
}
