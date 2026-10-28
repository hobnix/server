#!/usr/bin/env bash
# help: read and change the common settings in machine.toml (language, gpu, notifyUrl, metrics, backupNewShares, incusUi, loginMessage, shareSnapshots, syncEveryHours, timeZone)
# help.de: die gängigen Einstellungen in machine.toml lesen und ändern (language, gpu, notifyUrl, metrics, backupNewShares, incusUi, loginMessage, shareSnapshots, syncEveryHours, timeZone)
# args: list | get <key> | set <key> <value> [--dry-run] | migrate-settings [--dry-run]
# Only the keys below, with checked values; everything else you edit by hand. The file is copied to
# /var/lib/hs/machine.toml.before-config first and left alone when the result does not parse.
# (Layout of the file: hs config sync. Check it: hs config check.)
# HS_MACHINE_FILE and HS_STATE_DIR point tests at other files.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
. "$here/lib/setting.sh"
machine=$(machine_file)
state=${HS_STATE_DIR:-/var/lib/hs}

# key|kind|allowed values / hint
keys='language|enum|en de
gpu|gpu|nvidia amd intel none
notifyUrl|string|a URL such as https://ntfy.sh/my-topic, or "none"
metrics|bool|true false
backupNewShares|bool|true false
syncEveryHours|int|1 2 3 4 6 8 12 24
incusUi|bool|true false
shareSnapshots|bool|true false
loginMessage|bool|true false
keyMap|word|a console keyboard layout such as de, us, uk, or "none"
timeZone|zone|a time zone such as Europe/Vienna (timedatectl list-timezones), or "none"'

usage() {
  say "usage: hs config list"
  say "       hs config get <key>"
  say "       hs config set <key> <value> [--dry-run]"
  say "keys: $(cut -d'|' -f1 <<<"$keys" | paste -sd' ')"
  exit 1
}

spec() { awk -F'|' -v k="$1" '$1 == k { print; exit }' <<<"$keys"; }

# options that live in /var/lib/hs/settings (config/schema.toml store = "settings"): no machine.toml, no rebuild
is_setting() { grep -qx "$1" <<<"$settings"; }
settings=$(PYTHONUTF8=1 "${HS_PYTHON:-python3}" "$here/schema-gen.py" settings 2>/dev/null | cut -f1 || true)

current() {   # current <key>: the value as written (TOML), or empty
  if is_setting "$1"; then setting_get "$1" 2>/dev/null || true; return; fi
  machine_get_json "$1" 2>/dev/null || true
}

cmd=${1:-list}
[ $# -eq 0 ] || shift
case "$cmd" in
  list)
    { thead 'Setting' 'Value'
      while IFS='|' read -r k _ _; do
        v=$(current "$k")
        printf '%s\t%s\n' "$k" "${v:-$(_tr '(not set)')}"
      done <<<"$keys"; } | table ;;
  get)
    [ $# -eq 1 ] || usage
    [ -n "$(spec "$1")" ] || fail "$(t "'%s' is not a key hs config handles." "$1")"
    v=$(current "$1"); echo "${v:-(not set)}" ;;
  set)
    dry=false; args=()
    for a in "$@"; do if [ "$a" = --dry-run ]; then dry=true; else args+=("$a"); fi; done
    set -- ${args[@]+"${args[@]}"}
    [ $# -eq 2 ] || usage
    key=$1; val=$2
    row=$(spec "$key")
    if [ -z "$row" ] && is_setting "$key"; then
      # a runtime setting that the table above does not list: checked by the rules of config/schema.toml (schema-gen.py rule)
      rule=$(PYTHONUTF8=1 "${HS_PYTHON:-python3}" "$here/schema-gen.py" rule "$key" 2>/dev/null || true)
      r_type=$(cut -f1 <<<"$rule"); r_choices=$(cut -f2 <<<"$rule"); r_min=$(cut -f3 <<<"$rule"); r_pattern=$(cut -f4 <<<"$rule"); r_hint=$(cut -f5 <<<"$rule")
      remove=false
      if [ "$val" = none ] || [ -z "$val" ]; then remove=true
      else
        case "$r_type" in
          bool) case "$val" in true|false) ;; *) fail "$(t "'%s' must be true or false" "$key")" ;; esac ;;
          int) case "$val" in ""|*[!0-9]*) fail "$(t "'%s' must be a whole number" "$key")" ;; esac ;;
        esac
        if [ -n "$r_choices" ]; then case " $r_choices " in *" $val "*) ;; *) fail "$(t "'%s' must be one of: %s" "$key" "$r_choices")" ;; esac; fi
        if [ -n "$r_min" ] && [ "$val" -lt "$r_min" ] 2>/dev/null; then fail "$(t "'%s' must be %s or more" "$key" "$r_min")"; fi
        if [ -n "$r_pattern" ] && ! grep -Eq -- "$r_pattern" <<<"$val"; then fail "$(t "'%s' must be %s" "$key" "${r_hint:-valid}")"; fi
      fi
      if $remove; then note "$(t 'settings: %s removed' "$key")"; else note "$(t 'settings: %s = %s' "$key" "$val")"; fi
      $dry && { note "Dry run: nothing changed."; exit 0; }
      if $remove; then setting_unset "$key"; else setting_set "$key" "$val"; fi
      ok "$(t '%s is set.' "$key")"
      note "$(t 'It takes effect at once; no rebuild is needed.')"
      exit 0
    fi
    [ -n "$row" ] || fail "$(t "'%s' is not a key hs config handles." "$key")"
    IFS='|' read -r _ kind allowed <<<"$row"
    tomlval=""; remove=false
    case "$kind" in
      enum|bool|int) case " $allowed " in *" $val "*) ;; *) fail "$(t "'%s' must be one of: %s" "$key" "$allowed")" ;; esac
                 if [ "$kind" = enum ]; then tomlval="\"$val\""; else tomlval=$val; fi ;;
      gpu)       case " $allowed " in *" $val "*) ;; *) fail "$(t "'%s' must be one of: %s" "$key" "$allowed")" ;; esac
                 if [ "$val" = none ]; then remove=true; else tomlval="\"$val\""; fi ;;
      string)    if [ "$val" = none ]; then remove=true
                 else
                   case "$val" in http://*|https://*) ;; *) fail "$(t "'%s' must be a URL (http:// or https://) or none." "$key")" ;; esac
                   esc=${val//\/\\}; esc=${esc//\"/\\\"}; tomlval="\"$esc\""
                 fi ;;
      word)      if [ "$val" = none ]; then remove=true
                 else
                   case "$val" in ""|*[!A-Za-z0-9_-]*) fail "$(t "'%s' must be a layout name such as de, us or uk (letters, digits, - and _), or none." "$key")" ;; esac
                   tomlval="\"$val\""
                 fi ;;
      zone)      if [ "$val" = none ]; then remove=true
                 else
                   case "$val" in */*|UTC) ;; *) fail "$(t "'%s' must be a time zone such as Europe/Vienna (list: timedatectl list-timezones), or none." "$key")" ;; esac
                   case "$val" in *[!A-Za-z0-9_/+-]*) fail "$(t "'%s' must be a time zone such as Europe/Vienna (list: timedatectl list-timezones), or none." "$key")" ;; esac
                   tomlval="\"$val\""
                 fi ;;
    esac
    if is_setting "$key"; then
      if $remove; then note "$(t 'settings: %s removed' "$key")"; else note "$(t 'settings: %s = %s' "$key" "${val}")"; fi
      $dry && { note "Dry run: nothing changed."; exit 0; }
      if $remove; then setting_unset "$key"; else setting_set "$key" "$val"; fi
      ok "$(t '%s is set.' "$key")"
      note "$(t 'It takes effect at once; no rebuild is needed.')"
      exit 0
    fi
    [ -f "$machine" ] || fail "$(t 'No %s.' "$machine")"
    if $remove; then line="# $key = ..."; else line="$key = $tomlval"; fi
    note "$(t 'machine.toml: %s' "$line")"
    $dry && { note "Dry run: nothing changed."; exit 0; }
    # an active line is replaced (or commented out), a commented one is revived in its place, else it is appended;
    # the tool re-reads the result and refuses to write when it does not parse
    if $remove; then machine_unset "$key" config || fail "The result would not parse. Nothing was changed."
    else machine_set "$key" "$tomlval" config || fail "The result would not parse. Nothing was changed."; fi
    ok "$(t '%s is set.' "$key")"
    note "$(t 'The old file: %s' "$state/machine.toml.before-config")"
    next_step "hs rebuild" ;;
  migrate-settings)
    # The runtime settings (language, loginMessage, icons, backupNewShares, notifyUrl, heartbeatUrl, webAccent, proxyStatusUrl,
    # vpsHost, webTerminal*) used to be lines of machine.toml. Move their values to /var/lib/hs/settings (a setting that is
    # there already stays as it is) and comment the lines out. `hs update` runs this once before it syncs machine.toml.
    dry=false; [ "${1:-}" != --dry-run ] || dry=true
    # a server that was connected to the router before the setting existed (the capability network)
    if [ -z "$(setting_get networkProvider 2>/dev/null || true)" ] && { [ -e "$state/unifi" ] || [ -L "$state/unifi" ]; }; then
      if $dry; then note "$(t 'networkProvider = unifi would be set (the router is connected)')"
      else setting_set networkProvider unifi && ok "$(t 'networkProvider set to unifi (the router is connected)')"; fi
    fi
    [ -f "$machine" ] || exit 0
    moved=0
    for k in $settings; do
      machine_has "$k" || continue
      v=$(machine_get "$k" 2>/dev/null) || continue
      moved=$((moved + 1))
      if $dry; then note "$(t '%s = %s would move to the runtime settings' "$k" "$v")"; continue; fi
      [ -r "$(setting_path "$k")" ] || setting_set "$k" "$v"
      machine_unset "$k" migrate-settings >/dev/null || fail "$(t "'%s' could not be taken out of machine.toml. Nothing else was changed." "$k")"
    done
    if [ "$moved" -eq 0 ]; then [ -n "${HS_QUIET_OK:-}" ] || note "$(t 'Nothing to move: machine.toml has no runtime settings.')"
    elif ! $dry; then ok "$(t '%s setting(s) moved from machine.toml to %s' "$moved" "$(setting_dir)")"; fi ;;
  *) usage ;;
esac
