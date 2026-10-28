#!/usr/bin/env bash
# help: the UPS (battery backup): charge, runtime, load; needs `ups` in machine.toml
# help.de: die USV (Batterie-Notstrom): Ladung, Laufzeit, Last; braucht `ups` in machine.toml
# args: [show | status | event <message> | deadline]
# show (default, hs ups): a person's view with the ui components. status (hs sys ups status): key<TAB>value lines from `upsc`, no root,
# exit 0 also when the UPS cannot be read (reachable=no); keys: configured, name, reachable, status (raw ups.status), state
# (online|battery|low|unknown), charge (%), runtime (s), load (%), input_voltage, model, replace (yes|no).
# event: called by upsmon (NOTIFYCMD, NOTIFYTYPE and UPSNAME in the environment): sends the push message (alarm on power loss, ok on
# return, stop on shutdown) and starts/stops the "N minutes on battery" countdown (hs-ups-deadline). deadline: when the countdown ends and the
# power is still out, ask upsmon for a forced shutdown (the same clean path as a low battery). Push messages are never translated.
# /etc/hs/ups (written by configuration.nix) holds name=<ups> and shutdownMinutes=<N, 0 = only on low battery>.
# Test knobs: HS_UPS_CONF, HS_UPSC, HS_NOTIFY, HS_SYSTEMD_RUN, HS_SYSTEMCTL, HS_UPSMON, HS_POWEROFF.
set -uo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
conf=${HS_UPS_CONF:-/etc/hs/ups}

cval() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n1; }
configured() { [ -f "$conf" ]; }
name=$(cval name); name=${name:-ups}
minutes=$(cval shutdownMinutes); minutes=${minutes:-0}
notify() { bash "${HS_NOTIFY:-$here/notify.sh}" "$@" || true; }

# reading: fills r_* variables from upsc (5 s limit)
read_ups() {
  r_reach=no r_status="" r_charge="" r_runtime="" r_load="" r_vin="" r_model=""
  local out k v
  out=$(timeout 5 "${HS_UPSC:-upsc}" "$name@localhost" 2>/dev/null </dev/null) || return 0
  [ -n "$out" ] || return 0
  r_reach=yes
  while IFS=': ' read -r k v; do
    case "$k" in
      ups.status) r_status=$v ;;
      battery.charge) r_charge=$v ;;
      battery.runtime) r_runtime=$v ;;
      ups.load) r_load=$v ;;
      input.voltage) r_vin=$v ;;
      ups.model|device.model) [ -n "$r_model" ] || r_model=$v ;;
    esac
  done <<<"$out"
  return 0
}
state_of() {   # raw ups.status flags -> online|battery|low|unknown
  case " $1 " in
    *" LB "*) echo low ;;
    *" OB "*|*" DISCHRG "*) echo battery ;;
    *" OL "*) echo online ;;
    *) echo unknown ;;
  esac
}
replace_of() { case " $1 " in *" RB "*) echo yes ;; *) echo no ;; esac; }

cmd=${1:-show}
case "$cmd" in
  status)
    if ! configured; then printf 'configured\tno\n'; exit 0; fi
    read_ups
    printf 'configured\tyes\nname\t%s\nreachable\t%s\nstatus\t%s\nstate\t%s\ncharge\t%s\nruntime\t%s\nload\t%s\ninput_voltage\t%s\nmodel\t%s\nreplace\t%s\n' \
      "$name" "$r_reach" "$r_status" "$(state_of "$r_status")" "$r_charge" "$r_runtime" "$r_load" "$r_vin" "$r_model" "$(replace_of "$r_status")"
    ;;
  show)
    if ! configured; then
      warn "No UPS is set up."
      next_step "set ups in machine.toml, then hs rebuild"
      exit 0
    fi
    read_ups
    if [ "$r_reach" != yes ]; then
      status_line "UPS" "not reachable" bad
      note "upsc $name@localhost gives nothing: journalctl -u upsd -u upsdrv"
      exit 1
    fi
    st=$(state_of "$r_status")
    case "$st" in
      online) status_line "Power" "mains power" ok ;;
      battery) status_line "Power" "ON BATTERY" warn ;;
      low) status_line "Power" "ON BATTERY, battery low" bad ;;
      *) status_line "Power" "unknown ($r_status)" warn ;;
    esac
    [ "$(replace_of "$r_status")" = no ] || warn "The battery should be replaced."
    kv "Name" "$name${r_model:+ ($r_model)}"
    [ -z "$r_charge" ] || kv "Charge" "$r_charge %"
    [ -z "$r_runtime" ] || kv "Runtime" "$(t '%s min' "$((${r_runtime%.*} / 60))")"
    [ -z "$r_load" ] || kv "Load" "$r_load %"
    [ -z "$r_vin" ] || kv "Input voltage" "$r_vin V"
    if [ "$minutes" -gt 0 ]; then kv "Shutdown" "$(t 'after %s min on battery, or when the battery is low' "$minutes")"
    else kv "Shutdown" "$(t 'when the battery is low')"; fi
    ;;
  event)
    msg=${2:-}; type=${NOTIFYTYPE:-${msg%% *}}; host=$(hostname)
    systemctl_=${HS_SYSTEMCTL:-systemctl}
    case "$type" in
      ONBATT)
        extra=""
        [ "$minutes" -le 0 ] || extra=" It shuts down after $minutes min or when the battery is low."
        notify --category alarm "$host: power failure" "The mains power is out, the server runs on the UPS battery.$extra" high
        if [ "$minutes" -gt 0 ]; then
          "${HS_SYSTEMD_RUN:-systemd-run}" --unit=hs-ups-deadline --on-active="${minutes}m" --description="Shut down after $minutes min on UPS battery" \
            "$(command -v bash)" "$(readlink -f "$0")" deadline >/dev/null 2>&1 || true
        fi ;;
      ONLINE)
        "$systemctl_" stop hs-ups-deadline.timer hs-ups-deadline.service >/dev/null 2>&1 || true
        notify --category ok "$host: power is back" "The mains power is back, the shutdown countdown is cancelled." default ;;
      LOWBATT) notify --category alarm "$host: battery low" "The UPS battery is almost empty. The server shuts down now." urgent ;;
      FSD|SHUTDOWN) notify --category stop "$host: shutting down (UPS)" "The server shuts down cleanly because of the power failure." high ;;
      COMMBAD) notify --category problem "$host: UPS not reachable" "Lost contact with the UPS. Look: hs ups" high ;;
      COMMOK) notify --category ok "$host: UPS reachable again" "Contact with the UPS is back." low ;;
      REPLBATT) notify --category problem "$host: UPS battery" "The UPS reports that its battery should be replaced." default ;;
      *) ;;
    esac
    ;;
  deadline)
    configured || exit 0
    read_ups
    case "$(state_of "$r_status")" in
      battery|low)
        notify --category stop "$(hostname): shutting down (UPS)" "$minutes min on battery: shutting down cleanly." high
        "${HS_UPSMON:-upsmon}" -c fsd 2>/dev/null || ${HS_POWEROFF:-systemctl poweroff} ;;
    esac
    ;;
  *) say "usage: hs ups"; exit 1 ;;
esac
exit 0
