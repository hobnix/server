#!/usr/bin/env bash
# help: keep the output of the slow reads of the web interface in the state database, so a page opens without waiting for the scripts
# help.de: die Ausgabe der langsamen Lesezugriffe der Weboberfläche in der Zustandsdatenbank halten, damit eine Seite ohne Warten auf die Skripte aufgeht
# args: [--all] [--list]
# The collector behind the Docs of the cache: for every line of scripts/lib/collected-reads.tsv
# (the words of a `hs sys` read, TAB, how often in seconds) whose kept output is older than that, it runs the read and keeps the output, the exit code
# and the milliseconds it took in the table `reads` of /var/lib/hs/state.db (scripts/state-db.py read-put: the one writer). The web interface serves a kept
# output that is not older than a few minutes instead of starting the script itself; a collector that stops therefore only means the web interface runs
# the scripts itself again (what it always did). The timer hs-reads-collect starts this every 15 s while webUi is on; the storage locked: nothing runs.
#   --all    ignore the intervals and read everything now
#   --list   only print what would be read (key, interval, age of the kept output)
#   --status the same with what the web interface shows on its Data page: key, interval, age (-1 = never kept), milliseconds, exit code, bytes
# Test knobs: HS_COLLECTED_FILE (the list), HS_BIN (stand-in for the hs dispatcher), HS_STATE_SH (stand-in for state.sh), HS_LOCKED_MARKER, HS_NOW.
set -euo pipefail
here=$(dirname "$0")
list=${HS_COLLECTED_FILE:-$here/lib/collected-reads.tsv}
hsbin=${HS_BIN:-$here/lib/hs.sh}
state=${HS_STATE_SH:-$here/state.sh}
all=false only_list=false status=false
for a in "$@"; do
  case "$a" in --all) all=true ;; --list) only_list=true ;; --status) status=true; only_list=true ;; *) echo "usage: hs sys reads collect [--all] [--list|--status]" >&2; exit 1 ;; esac
done

[ -f "$list" ] || exit 0
if ! $only_list && [ -e "${HS_LOCKED_MARKER:-/run/hs/storage-locked}" ]; then exit 0; fi   # the reads need the storage; the old output stays

declare -A age=() took=() code=() size=()
while IFS=$'\t' read -r k a ms rc bytes _; do [ -z "$k" ] || { age[$k]=$a; took[$k]=${ms:--}; code[$k]=${rc:--}; size[$k]=${bytes:--}; }; done < <(bash "$state" reads 2>/dev/null || true)

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

while IFS=$'\t' read -r key every _; do
  [[ -n "$key" && "$key" != \#* ]] || continue
  [[ "$every" =~ ^[0-9]+$ ]] || every=30
  have=${age[$key]:--1}
  if $status; then printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$every" "$have" "${took[$key]:--}" "${code[$key]:--}" "${size[$key]:--}"; continue; fi
  if $only_list; then printf '%s\t%s\t%s\n' "$key" "$every" "$have"; continue; fi
  if ! $all && [ "$have" -ge 0 ] && [ "$have" -lt "$every" ]; then continue; fi
  t0=$(now_ms); rc=0
  # shellcheck disable=SC2086
  out=$(HS_CALLER=ui timeout 90 bash "$hsbin" sys $key 2>/dev/null </dev/null) || rc=$?
  t1=$(now_ms)
  # a failed read with no output keeps the older output (and says nothing): the web interface falls back to running it
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then continue; fi
  printf '%s' "$out" | bash "$state" read-put "$key" --ms $((t1 - t0)) --rc "$rc" || true
done < "$list"
