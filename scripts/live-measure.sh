#!/usr/bin/env bash
# help: measure the live state on the state database for a while (writes per minute, database growth, change latency) and write a result file; needs root
# args: [--minutes <N>] [--probe-every <S>] [--out <file>]
# ADR 0026 step 1 (issue #481): runs scripts/live_measure.py for N minutes (default 30), which probes the change latency every S seconds (default 10)
# and writes <file>.md and <file>.tsv (default /var/lib/hs/live-measure-<date>). Meant for liveState = "db"; in other modes only the latency
# and the old collector are measured. Changes nothing but the probe counter live:probe.
# Test knobs: HS_STATE_DB, HS_WEB_PROBE_FILE, HS_STATE_PY (state-db.py), HS_MACHINE_FILE.
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/machine.sh"
usage="usage: hs live measure [--minutes <N>] [--probe-every <S>] [--out <file>]"
minutes=30 every=10 out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes|--probe-every|--out)
      [ $# -ge 2 ] || { help_usage "$usage"; exit 1; }
      case "$1" in
        --minutes)     minutes=$2 ;;
        --probe-every) every=$2 ;;
        --out)         out=$2 ;;
      esac
      shift 2 ;;
    *) help_usage "$usage"; exit 1 ;;
  esac
done
[[ "$minutes" =~ ^[0-9]+$ ]] && [ "$minutes" -ge 1 ] && [ "$minutes" -le 1440 ] || { help_usage "$usage"; exit 1; }
[[ "$every" =~ ^[0-9]+$ ]] && [ "$every" -ge 2 ] && [ "$every" -le 300 ] || { help_usage "$usage"; exit 1; }
[ -n "$out" ] || out="${HS_STATE_DIR:-/var/lib/hs}/live-measure-$(date +%Y%m%d-%H%M)"

mode=$(machine_get liveState 2>/dev/null || echo off)
step "Measure the live state for $minutes minutes"
if [ "$mode" != db ]; then
  warn "liveState is \"$mode\", not \"db\": only the change latency and the old collector are measured"
fi
SPIN_STREAM=1 spin "Measuring" python3 "$here/live_measure.py" --seconds $((minutes * 60)) --probe-every "$every" --out "$out" --mode "$mode" \
  || fail "the measurement did not finish (is there a state database?)"
KV_WIDTH=36
export KV_WIDTH
while IFS=$'\t' read -r k v; do
  [ -z "$k" ] || kv "$k" "$v"
done < "$out.tsv"
ok "Result: $out.md (paste it into issue #481)"
