#!/usr/bin/env bash
# help: change one common setting in machine.toml without asking anything: what would happen (plan), then do it (start)
# help.de: eine gängige Einstellung in machine.toml ändern, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start set <key> <value> | sync | migrate
# System command (hs sys config plan|start), for the interface and tests. It never asks and prints plain key<TAB>value lines like
# jobs-change.sh and backup-change.sh.
#   set <key> <value>   write the option into machine.toml (an empty value switches the option off again: the default applies).
#                       Only the keys in scripts/lib/config-keys.sh (CONFIG_SETTABLE); the value must fit the type of the option in
#                       machine.toml.example: bool = true|false, number = a whole number, string = text (turned into a TOML string here).
#                       Secrets (notifyUrl, heartbeatUrl, sshKeys) and lists/tables are not changed from the interface.
#   sync                put machine.toml in the layout of machine.toml.example (new options in their place, commented out); the plan lists the new
#                       options and refuses when there are none. A copy of the old file goes to $HS_STATE_DIR/machine.toml.before-sync.
#   migrate             convert an old machine.nix to machine.toml (the old file becomes machine.nix.migrated); refused when machine.toml exists already
#                       or there is no machine.nix
#
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text> | heading|step|note|warn|command<TAB><line>, long<TAB>no.
# start: the same checks; edits the file (a copy goes to $HS_STATE_DIR/machine.toml.before-config), runs the check of `hs config check`
#   and puts the old file back when it reports an error; prints status done. Nothing is rebuilt: the change takes effect with hs rebuild.
# Test knobs: HS_MACHINE_FILE, HS_MACHINE_EXAMPLE, HS_STATE_DIR, HS_PYTHON.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/machine.sh"
. "$here/lib/setting.sh"
. "$here/lib/config-keys.sh"

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; key=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: config-change.sh plan|start set <key> <value>" >&2; exit 1 ;; esac
case "$action" in
  sync|migrate)
    [ $# -eq 2 ] || refuse "unexpected extra arguments"
    sync_sh=${HS_MACHINE_SYNC:-$here/machine-sync.sh}
    export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
    unset HS_GUIDED_TTY
    if [ "$action" = sync ]; then
      [ -f "$(machine_file)" ] || refuse "There is no machine.toml on this server."
      news=$(bash "$sync_sh" --list </dev/null 2>/dev/null || true)
      [ -n "$news" ] || refuse "Nothing is new: machine.toml is in the layout of the example already."
      if [ "$verb" = start ]; then
        bash "$sync_sh" sync </dev/null >/dev/null 2>&1 || refuse "machine.toml could not be rewritten (it is left as it was)"
        printf 'status\tdone\n'
        exit 0
      fi
      printf 'status\tok\nheading\tput machine.toml in the layout of the example\n'
      while IFS=$'\t' read -r _ opt desc; do printf 'step\tnew option %s: %s\n' "$opt" "$desc"; done <<<"$news"
      printf 'note\tThe new options appear commented out, nothing changes until you switch one on. Your values stay; a copy of the old file is kept.\n'
      printf 'command\ths config sync\nlong\tno\n'
      exit 0
    fi
    machine=$(machine_file)
    old=${HS_MACHINE_OLD:-$(dirname "$machine")/machine.nix}
    [ ! -f "$machine" ] || refuse "machine.toml exists already: nothing to convert."
    [ -f "$old" ] || refuse "There is no machine.nix to convert."
    if [ "$verb" = start ]; then
      bash "$sync_sh" migrate </dev/null >/dev/null 2>&1 || refuse "machine.nix could not be converted (it is left as it was)"
      printf 'status\tdone\n'
      exit 0
    fi
    printf 'status\tok\nheading\tconvert machine.nix to machine.toml\n'
    printf 'step\tread the old machine.nix and write machine.toml in the layout of the example\n'
    printf 'step\tkeep the old file as machine.nix.migrated\n'
    printf 'note\tNothing is rebuilt. Compare the result with the example and run hs rebuild when it looks right.\n'
    printf 'command\ths config migrate\nlong\tno\n'
    exit 0 ;;
esac
[ "$action" = set ] || refuse "unknown action (set, sync or migrate)"
[ $# -ge 4 ] || refuse "set needs a key and a value"
value=$4
case " $CONFIG_SETTABLE " in *" $key "*) ;; *) refuse "'$key' can not be changed from the interface (edit machine.toml on the server)." ;; esac
machine=$(machine_file)
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
[ -f "$machine" ] || refuse "There is no machine.toml on this server."

# the type of the option, from the example (the one schema)
type=$(bash "$here/config-read.sh" list 2>/dev/null | awk -F'\t' -v k="$key" '$2 == k { print $5; exit }')
[ -n "$type" ] || refuse "'$key' is not an option of machine.toml.example."

toml=""; off=false
if [ -z "$value" ]; then off=true
else
  case "$type" in
    bool) case "$value" in true|false) toml=$value ;; *) refuse "'$key' must be true or false." ;; esac ;;
    number)
      [[ "$value" =~ ^[0-9]{1,6}$ ]] || refuse "'$key' must be a whole number."
      toml=$value ;;
    string)
      [[ "$value" != *[\"\\]* ]] || refuse "Quotes and backslashes are not allowed in a value."
      toml="\"$value\"" ;;
    *) refuse "'$key' is a list or table: edit machine.toml on the server." ;;
  esac
fi

# allowed values, minimum and pattern come from config/schema.toml (scripts/schema-gen.py rule)
if ! $off; then
  rule=$(PYTHONUTF8=1 "$py" "$here/schema-gen.py" rule "$key" 2>/dev/null || true)
  r_choices=$(cut -f2 <<<"$rule"); r_min=$(cut -f3 <<<"$rule"); r_pattern=$(cut -f4 <<<"$rule"); r_hint=$(cut -f5 <<<"$rule")
  if [ -n "${r_choices:-}" ]; then case " $r_choices " in *" $value "*) ;; *) refuse "'$key' must be one of: $r_choices." ;; esac; fi
  if [ -n "${r_min:-}" ] && [ "$value" -lt "$r_min" ] 2>/dev/null; then refuse "'$key' must be $r_min or more."; fi
  if [ -n "${r_pattern:-}" ] && ! grep -Eq -- "$r_pattern" <<<"$value"; then refuse "'$key' must be ${r_hint:-valid}."; fi
fi

store=$(bash "$here/config-read.sh" list 2>/dev/null | awk -F'\t' -v k="$key" '$2 == k { print $8; exit }')

# runtime settings (store = settings): one file in /var/lib/hs/settings, no machine.toml, no rebuild
if [ "$store" = settings ]; then
  old=$(setting_get "$key" 2>/dev/null || true)
  if $off; then
    [ -r "$(setting_path "$key")" ] || refuse "'$key' is not set already."
  elif [ "$old" = "$value" ] && [ -r "$(setting_path "$key")" ]; then
    refuse "'$key' is $value already."
  fi
  if [ "$verb" = start ]; then
    if $off; then setting_unset "$key"; else setting_set "$key" "$value"; fi
    printf 'status\tdone\n'
    exit 0
  fi
  echo "status	ok"
  if $off; then
    printf 'heading\tswitch off %s\n' "$key"
    printf 'step\tremove the setting %s; the default applies again\n' "$key"
    printf 'command\ths sys config start set %s ""\n' "$key"
  else
    printf 'heading\tset %s\n' "$key"
    printf 'step\twrite %s = %s to %s\n' "$key" "$value" "$(setting_path "$key")"
    printf 'command\ths sys config start set %s %s\n' "$key" "$value"
  fi
  printf 'note\tThis setting takes effect at once; no rebuild is needed.\n'
  printf 'long\tno\n'
  exit 0
fi

old=$(machine_get "$key" 2>/dev/null || true)
if $off; then
  machine_has "$key" || refuse "'$key' is not set already."
elif machine_has "$key" && [ "$old" = "$value" ]; then
  refuse "'$key' is $value already."
fi

if [ "$verb" = start ]; then
  keep=$(mktemp); trap 'rm -f "$keep"' EXIT
  cp -p "$machine" "$keep"
  if $off; then machine_unset "$key" >/dev/null || { cp -p "$keep" "$machine"; refuse "machine.toml was not changed."; }
  else machine_set "$key" "$toml" >/dev/null || { cp -p "$keep" "$machine"; refuse "machine.toml was not changed."; }
  fi
  if ! bash "$here/config-read.sh" check >/dev/null 2>&1; then
    cp -p "$keep" "$machine"
    refuse "machine.toml would have problems after that change (hs config check); it was put back."
  fi
  printf 'status\tdone\n'
  exit 0
fi

echo "status	ok"
if $off; then
  printf 'heading\tswitch off %s\n' "$key"
  printf 'step\tcomment %s out in machine.toml (it was %s); the default applies again\n' "$key" "${old:-set}"
  printf 'command\ths sys config start set %s ""\n' "$key"
else
  printf 'heading\tset %s\n' "$key"
  if machine_has "$key"; then printf 'step\tchange %s in machine.toml from %s to %s\n' "$key" "$old" "$value"
  else printf 'step\tswitch %s on in machine.toml with the value %s\n' "$key" "$value"; fi
  printf 'command\ths sys config start set %s %s\n' "$key" "$value"
fi
printf 'step\tcheck machine.toml afterwards and put the old file back if the check fails\n'
printf 'note\tThe change takes effect with hs rebuild; the old file is kept as machine.toml.before-config.\n'
printf 'long\tno\n'
exit 0
