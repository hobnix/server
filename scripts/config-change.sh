#!/usr/bin/env bash
# help: change one common setting in machine.toml without asking anything: what would happen (plan), then do it (start)
# help.de: eine gängige Einstellung in machine.toml ändern, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start set <key> <value> [--confirm <name>] | apply --set <key>=<value> ... [--confirm <name>] | sync | migrate
# System command (hs sys config plan|start), for the interface and tests. It never asks and prints plain key<TAB>value lines like
# jobs-change.sh and backup-change.sh.
#   set <key> <value>   write the option into machine.toml (an empty value switches the option off again: the default applies).
#                       Only the keys in scripts/lib/config-keys.sh (CONFIG_SETTABLE); the value must fit the type of the option in
#                       machine.toml.example: bool = true|false, number = a whole number, string = text (turned into a TOML string here).
#                       Secrets (notifyUrl, heartbeatUrl, sshKeys) and lists/tables are not changed from the interface; the one list that can
#                       be is dhcpRange (two numbers: `100 199`, `[100, 199]` or `100-199`, written as TOML `[100, 199]`).
#                       check_extra adds per-key checks (nic must be a physical card, smbAllow/dhcpRange/siteName syntax) and warn/danger lines.
#   apply --set k=v ... several keys in one plan and one start (the guided setup). Every key passes the checks of set and nothing is
#                       written before all pass; the machine.toml keys are written together and put back together when the check fails,
#                       then the runtime settings are written. An empty value (k=) switches a key off.
#   sync                put machine.toml in the layout of machine.toml.example (new options in their place, commented out); the plan lists the new
#                       options and refuses when there are none. A copy of the old file goes to $HS_STATE_DIR/machine.toml.before-sync.
#   migrate             convert an old machine.nix to machine.toml (the old file becomes machine.nix.migrated); refused when machine.toml exists already
#                       or there is no machine.nix
#
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text> | heading|step|note|warn|danger|confirm_name|command<TAB><line>, long<TAB>no.
# start: the same checks; edits the file (a copy goes to $HS_STATE_DIR/machine.toml.before-config), runs the check of `hs config check`
#   and puts the old file back when it reports an error; prints status done. Nothing is rebuilt: the change takes effect with hs rebuild.
# Test knobs: HS_MACHINE_FILE, HS_MACHINE_EXAMPLE, HS_STATE_DIR, HS_PYTHON, HS_SYS_NET, HS_HOST_NET, HS_SITE_NAME_FILE, HS_CAPABILITIES_FILE.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/machine.sh"
. "$here/lib/setting.sh"
. "$here/lib/capability.sh"
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
[ "$action" = set ] || [ "$action" = apply ] || refuse "unknown action (set, apply, sync or migrate)"
machine=$(machine_file)
py=${HS_PYTHON:-python3}; command -v "$py" >/dev/null 2>&1 || py=python
list=""
extra=""
confirm=""

# shq <text>: the text as one shell word for the printed command (single quotes only when it has a space or a quote)
shq() {
  case "$1" in
    *[$' \t\'']*) local q=${1//\'/\'\\'\'}; printf "'%s'" "$q" ;;
    *) printf '%s' "$1" ;;
  esac
}

# need_confirm <key> <value>: start must carry --confirm <new card name> for nic (plans are not checked)
need_confirm() {
  [ "$verb" = start ] && [ "$1" = nic ] || return 0
  [ "$confirm" = "$2" ] || refuse "type the name of the network card to confirm: $2"
}

# dhcp_norm <value>: sets norm to "from to" (removes [ ] , and turns - into a space); "?" when it is not two words
dhcp_norm() {
  local v=${1//[\[\],]/ } a b rest
  v=${v//-/ }
  read -r a b rest <<<"$v" || true
  if [ -n "${rest:-}" ] || [ -z "${b:-}" ]; then norm="?"; else norm="$a $b"; fi
}

# check_key <key> <value>: refuses, or sets type toml off store old for the key (the checks of set and apply)
check_key() {
  local key=$1 value=$2 rule r_choices r_min r_pattern r_hint
  case " $CONFIG_SETTABLE " in *" $key "*) ;; *) refuse "'$key' can not be changed from the interface (edit machine.toml on the server)." ;; esac
  [ -f "$machine" ] || refuse "There is no machine.toml on this server."

  # the type of the option, from the example (the one schema)
  # no `exit` in awk: it closes the pipe, config-read.sh gets SIGPIPE and pipefail + set -e end the script without a word
  [ -n "$list" ] || list=$(bash "$here/config-read.sh" list 2>/dev/null || true)
  type=$(awk -F'\t' -v k="$key" '$2 == k && !f { print $5; f = 1 }' <<<"$list")
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
      list)
        [ "$key" = dhcpRange ] || refuse "'$key' is a list or table: edit machine.toml on the server."
        dhcp_norm "$value"
        # leading zeros (010, 08) are read as octal by bash and rejected by TOML: write plain numbers
        [[ "$norm" =~ ^[0-9]{1,3}\ [0-9]{1,3}$ ]] && norm="$((10#${norm% *})) $((10#${norm#* }))"
        [[ "$norm" =~ ^[0-9]{1,3}\ [0-9]{1,3}$ ]] && [ "${norm% *}" -ge 1 ] && [ "${norm% *}" -lt "${norm#* }" ] && [ "${norm#* }" -le 254 ] \
          || refuse "dhcpRange must be two numbers from 1 to 254, the first smaller, e.g. 100 199"
        toml="[${norm% *}, ${norm#* }]" ;;
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

  store=$(awk -F'\t' -v k="$key" '$2 == k && !f { print $8; f = 1 }' <<<"$list")
  if [ "$store" = settings ]; then
    old=$(setting_get "$key" 2>/dev/null || true)
    if $off; then
      [ -r "$(setting_path "$key")" ] || refuse "'$key' is not set already."
    elif [ "$old" = "$value" ] && [ -r "$(setting_path "$key")" ]; then
      refuse "'$key' is $value already."
    fi
  else
    old=$(machine_get "$key" 2>/dev/null || true)
    cmp=$value
    if [ "$type" = list ]; then old=$(tr '\n' ' ' <<<"$old"); old=${old% }; cmp=${toml//[\[\],]/}; fi
    if $off; then
      machine_has "$key" || refuse "'$key' is not set already."
    elif machine_has "$key" && [ "$old" = "$cmp" ]; then
      refuse "'$key' is $value already."
    fi
  fi
}

# xline <kind> <text>: appends one plan line to extra
xline() { extra="$extra$1"$'\t'"$2"$'\n'; }

# check_extra <key> <value>: the per-key rules; refuses, or appends plan lines (warn/danger/confirm_name/note) to extra
check_extra() {
  local k=$1 v=$2 net bad out old_site
  case "$k" in
    nic)
      [ -n "$v" ] || refuse "nic cannot be switched off."
      [[ "$v" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || refuse "'nic' must be a network card name such as enp3s0."
      net=${HS_SYS_NET:-/sys/class/net}
      [ -e "$net/$v" ] || refuse "There is no network card called $v on this server (see ip link)."
      [ -e "$net/$v/device" ] || refuse "$v is not a physical network card (a bridge, VLAN or tunnel)."
      xline danger "The server takes its network from $v after hs rebuild. If the cable is not in that port, the server is offline: no SSH, no web, no Tailscale. The way back is a keyboard and screen at the server: hold the space bar while it starts and pick the previous generation."
      xline confirm_name "$v"
      [ "$(cat "$net/$v/carrier" 2>/dev/null || true)" = 1 ] || xline warn "No cable is connected to $v right now." ;;
    smbAllow)
      [ -n "$v" ] || refuse "smbAllow cannot be switched off."
      # shellcheck disable=SC2086
      bad=$("$py" -c 'import ipaddress,sys
for t in sys.argv[1:]:
    try: ipaddress.IPv4Network(t, strict=True)
    except ValueError: print(t); break' $v 2>/dev/null || true)
      [ -z "$bad" ] || refuse "'$bad' is not an IPv4 address or network such as 10.10.10.0/24 (no host bits after the slash)."
      if [ -n "${HS_HOST_NET+x}" ]; then net=$HS_HOST_NET
      else
        net=$(ip -4 -o addr show br0 2>/dev/null | awk '{ print $4; exit }' || true)
        [ -z "$net" ] || net=$("$py" -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$net" 2>/dev/null || true)
      fi
      if [ -n "$net" ]; then
        # shellcheck disable=SC2086
        out=$("$py" -c 'import ipaddress,sys
h = ipaddress.IPv4Network(sys.argv[1], strict=False)
print("in" if any(h.subnet_of(ipaddress.IPv4Network(t, strict=True)) for t in sys.argv[2:]) else "out")' "$net" $v 2>/dev/null || echo in)
        [ "$out" != out ] || xline warn "The server's own network $net is not in the list: PCs there can no longer open the shares."
      fi
      xline note "Only the Samba shares are affected; SSH and the web interface stay reachable." ;;
    dhcpRange)
      [ -z "$v" ] || xline note "This only tells hs ct list which addresses your router hands out; set the same range on the router. Nothing on the network changes." ;;
    siteName)
      if [ -n "$v" ] && capability_on gateway; then
        old_site=$(machine_get siteName 2>/dev/null || true)
        [ -n "$old_site" ] || old_site=$(cat "${HS_SITE_NAME_FILE:-/etc/hs/site-name}" 2>/dev/null || true)
        xline warn "The local names change from <svc>.${old_site:-<old>}.<domain> to <svc>.$v.<domain>. Create the DNS record *.$v in the domain first; until then the new names do not resolve."
      fi ;;
    incusUi)
      [ "$v" != false ] || xline warn "Port 8443 closes: the Incus web UI and incus remote clients stop working. An address set earlier stays until incus config unset core.https_address." ;;
  esac
}

# step_line <key> <value>: the plan step of one key (the wording of set)
step_line() {
  if [ "$store" = settings ]; then
    if $off; then printf 'step\tremove the setting %s; the default applies again\n' "$1"
    else printf 'step\twrite %s = %s to %s\n' "$1" "$2" "$(setting_path "$1")"; fi
  elif $off; then printf 'step\tcomment %s out in machine.toml (it was %s); the default applies again\n' "$1" "${old:-set}"
  elif machine_has "$1"; then printf 'step\tchange %s in machine.toml from %s to %s\n' "$1" "$old" "$2"
  else printf 'step\tswitch %s on in machine.toml with the value %s\n' "$1" "$2"; fi
}

if [ "$action" = apply ]; then
  shift 2
  [ $# -gt 0 ] || refuse "apply needs at least one --set key=value"
  keys=(); offs=(); tomls=(); stores=(); vals=(); steps=(); seen=" "; n_machine=0; cmd=""
  while [ $# -gt 0 ]; do
    if [ "$1" = --confirm ]; then
      [ $# -ge 2 ] || refuse "--confirm needs a value"
      confirm=$2; shift 2; continue
    fi
    { [ "$1" = --set ] && [ $# -ge 2 ]; } || refuse "apply takes only --set key=value and --confirm <name>"
    pair=$2; shift 2
    case "$pair" in *=*) ;; *) refuse "'$pair' is not key=value." ;; esac
    k=${pair%%=*}; v=${pair#*=}
    case "$seen" in *" $k "*) refuse "'$k' is given twice." ;; esac
    seen="$seen$k "
    check_key "$k" "$v"
    check_extra "$k" "$v"
    keys+=("$k"); vals+=("$v"); offs+=("$off"); tomls+=("$toml"); stores+=("$store")
    steps+=("$(step_line "$k" "$v")")
    [ "$store" = settings ] || n_machine=$((n_machine + 1))
    cmd="$cmd --set $(shq "$k=$v")"
  done
  if [ "$verb" = start ]; then for i in "${!keys[@]}"; do need_confirm "${keys[$i]}" "${vals[$i]}"; done; fi
  if [ "$verb" = plan ]; then
    printf 'status\tok\nheading\tchange %s settings\n' "${#keys[@]}"
    for s in "${steps[@]}"; do printf '%s\n' "$s"; done
    [ -z "$extra" ] || printf '%s' "$extra"
    printf 'command\ths sys config start apply%s\n' "$cmd"
    if [ "$n_machine" -gt 0 ]; then printf 'note\tThe machine.toml changes take effect with hs rebuild; the old file is kept as machine.toml.before-config.\n'
    else printf 'note\tThis setting takes effect at once; no rebuild is needed.\n'; fi
    printf 'long\tno\n'
    exit 0
  fi
  keep=$(mktemp); trap 'rm -f "$keep"' EXIT
  cp -p "$machine" "$keep"
  if [ "$n_machine" -gt 0 ]; then
    done_keys=""
    for i in "${!keys[@]}"; do
      [ "${stores[$i]}" = settings ] && continue
      ok=0
      if [ "${offs[$i]}" = true ]; then machine_unset "${keys[$i]}" >/dev/null || ok=1
      else machine_set "${keys[$i]}" "${tomls[$i]}" >/dev/null || ok=1; fi
      if [ "$ok" = 1 ]; then
        cp -p "$keep" "$machine"
        refuse "machine.toml was not changed (${keys[$i]} failed${done_keys:+; written and put back:$done_keys}); no setting was written."
      fi
      done_keys="$done_keys ${keys[$i]}"
    done
    if ! bash "$here/config-read.sh" check >/dev/null 2>&1; then
      cp -p "$keep" "$machine"
      refuse "machine.toml would have problems after these changes (hs config check); it was put back, no setting was written."
    fi
    # machine_set/machine_unset keep the file as it was before THEIR key; the plan promises the file as it was before all of them
    cp -p "$keep" "${HS_STATE_DIR:-/var/lib/hs}/machine.toml.before-config" 2>/dev/null || true
  fi
  written=""
  for i in "${!keys[@]}"; do
    [ "${stores[$i]}" = settings ] || continue
    ok=0
    if [ "${offs[$i]}" = true ]; then setting_unset "${keys[$i]}" || ok=1; else setting_set "${keys[$i]}" "${vals[$i]}" || ok=1; fi
    if [ "$ok" = 1 ]; then
      [ "$n_machine" -eq 0 ] || cp -p "$keep" "$machine"
      refuse "${keys[$i]} could not be written${written:+; already written:$written}$([ "$n_machine" -eq 0 ] || echo '; machine.toml was put back')."
    fi
    written="$written ${keys[$i]}"
  done
  printf 'status\tdone\n'
  exit 0
fi

[ $# -ge 4 ] || refuse "set needs a key and a value"
value=$4
shift 4
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
check_key "$key" "$value"
check_extra "$key" "$value"
need_confirm "$key" "$value"

# runtime settings (store = settings): one file in /var/lib/hs/settings, no machine.toml, no rebuild
if [ "$store" = settings ]; then
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
    printf 'command\ths sys config start set %s %s\n' "$key" "$(shq "$value")"
  fi
  printf 'note\tThis setting takes effect at once; no rebuild is needed.\n'
  printf 'long\tno\n'
  exit 0
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
  [ -z "$extra" ] || printf '%s' "$extra"
  printf 'command\ths sys config start set %s %s\n' "$key" "$(shq "$value")"
fi
printf 'step\tcheck machine.toml afterwards and put the old file back if the check fails\n'
printf 'note\tThe change takes effect with hs rebuild; the old file is kept as machine.toml.before-config.\n'
printf 'long\tno\n'
exit 0
