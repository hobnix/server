# shellcheck shell=bash
# Runtime settings: the options of config/schema.toml with store = "settings" (docs/PLAN-modular-core.md step 2).
# One small file each in /var/lib/hs/settings/<key>, so reading one is a plain `cat` (language is read by every `hs`
# command); changing one needs no `hs rebuild`. Written by `hs sys config start set` / `hs config set`.
#
#   setting_get <key>          value on stdout (true|false, a number, or the text); 1 when set nowhere
#   setting_set <key> <value>  write it (atomic, readable by all); an empty value removes it
#   setting_unset <key>
#   setting_path <key>         the file
#
# The value is looked up in this order: the settings file; the old /etc/hs/<name> file that Nix still writes from
# machine.toml (the "legacy" file of the schema; on|off is read as true|false); otherwise not set, and the caller's own
# default applies. Test knobs: HS_SETTINGS_DIR, HS_STATE_DIR, HS_ETC_DIR.

setting_dir() { echo "${HS_SETTINGS_DIR:-${HS_STATE_DIR:-/var/lib/hs}/settings}"; }

# The push addresses keep the files they always had (outside the vault on purpose: the alarm "storage is locked" needs
# them, see scripts/secrets.sh). Everything else is <settings dir>/<key>.
setting_path() {
  case "$1" in
    notifyUrl) echo "${HS_STATE_DIR:-/var/lib/hs}/notify-url" ;;
    heartbeatUrl) echo "${HS_STATE_DIR:-/var/lib/hs}/heartbeat-url" ;;
    *) echo "$(setting_dir)/$1" ;;
  esac
}

# key -> /etc/hs file name (generated list; tests/schema.sh keeps it equal to the schema's `legacy` fields)
_setting_legacy() {
  case "$1" in
    language) echo language ;;
    icons) echo icons ;;
    loginMessage) echo login-message ;;
    backupNewShares) echo backup-new-shares ;;
    notifyUrl) echo notify-url ;;
    heartbeatUrl) echo heartbeat-url ;;
  esac
}

setting_get() {
  local f v leg
  f=$(setting_path "$1")
  if [ -r "$f" ]; then IFS= read -r v < "$f" || true; printf '%s\n' "$v"; return 0; fi
  leg=$(_setting_legacy "$1")
  [ -n "$leg" ] || return 1
  f="${HS_ETC_DIR:-/etc/hs}/$leg"
  [ -r "$f" ] || return 1
  IFS= read -r v < "$f" || true
  case "$1:$v" in
    loginMessage:on|backupNewShares:on) v=true ;;
    loginMessage:off|backupNewShares:off) v=false ;;
  esac
  printf '%s\n' "$v"
}

setting_set() {
  local f tmp
  if [ -z "${2-}" ]; then setting_unset "$1"; return; fi
  f=$(setting_path "$1")
  mkdir -p "$(dirname "$f")"
  tmp=$f.tmp-$$
  printf '%s\n' "$2" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$f"
}

setting_unset() { rm -f "$(setting_path "$1")"; }
