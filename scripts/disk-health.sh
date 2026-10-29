#!/usr/bin/env bash
# help: how healthy is a disk? SMART verdict (OK / WATCH / BAD), age, bad sectors, errors; starts a self-test
# help.de: wie gesund ist eine Platte? SMART-Befund (OK / WATCH / BAD), Alter, defekte Sektoren, Fehler; startet einen Selbsttest
# args: [<disk>] | --list | --test short|long <disk> | --results <disk> [--dry-run] | --readings [--wake <name,...>]
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
. "$here/lib/diskpath.sh"

usage() {
  say "usage: hs disk list                    every disk with its verdict"
  say "       hs disk <disk> health             the details of one disk (sdg, /dev/sdg or the name in /dev/disk/by-id)"
  say "       hs disk <disk> test short   start a self-test inside the disk (about 2 minutes)"
  say "       hs disk <disk> test long    the same, reading the whole surface (hours; the disk stays usable)"
  say "       hs disk <disk> results      the outcome of the last self-tests"
  say "       --list     the verdict list as tab separated lines (for the interface)"
  say "       --dry-run  with --test: only show the command"
  say "       --readings  one reading line per disk for the daily SMART check (tab separated)"
  say "       --wake <names>  with --readings: read only these disks, without the standby flag (wakes them)"
  say "Verdicts: OK = nothing to see; WATCH = works, but see the notes (old, reallocated sectors, cable errors, hot);"
  say "          BAD = replace it (failed assessment, pending sectors, failed self-test)."
  exit 1
}

dry=false
list=false
readings=false
wake=""
action=detail
kind=""
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=true; shift ;;
    --list)    list=true; shift ;;
    --readings) readings=true; shift ;;
    --wake)    [ $# -ge 2 ] || usage; wake=$2; shift 2 ;;
    --test)    [ $# -ge 3 ] || usage; action=test; kind=$2; target=$3; shift 3 ;;
    --results) [ $# -ge 2 ] || usage; action=results; target=$2; shift 2 ;;
    -*)        usage ;;
    *)         [ -z "$target" ] || usage; target=$1; shift ;;
  esac
done
case "$kind" in ""|short|long) ;; *) usage ;; esac

[ "$(id -u)" = 0 ] || [ -n "${HS_DISK_HEALTH_NOROOT:-}" ] || fail "SMART can only be read as root. Run it as: hs disk list"
command -v smartctl >/dev/null || fail "smartctl is not installed (package smartmontools)."

# sdg, /dev/sdg, by-id name or partition -> /dev/sdg
resolve() {
  local d=$1 p
  case "$d" in /dev/*) ;; sd*|nvme*|vd*) d=/dev/$d ;; *) d=/dev/disk/by-id/$d ;; esac
  [ -e "$d" ] || fail "$(t "No disk '%s'. See the list: hs disk list" "$1")"
  d=$(readlink -f "$d")
  p=$(lsblk -dno PKNAME "$d" 2>/dev/null | head -n1 || true)
  [ -z "$p" ] || d=/dev/$p
  [ "$(lsblk -dno TYPE "$d" 2>/dev/null)" = disk ] || fail "$(t '%s is not a disk.' "$1")"
  echo "$d"
}

# the SMART data as JSON; USB bridges often need "-d sat"
smart_json() {   # smart_json <dev> [standby]
  local dev=$1 flags=(-j -a) out alt
  [ -z "${2:-}" ] || flags=(-n standby -j -a)
  out=$(smartctl "${flags[@]}" "$dev" 2>/dev/null || true)
  if ! jq -e '.smart_status or ((.smartctl.messages // []) | map(.string) | join(" ") | test("STANDBY|SLEEP"))' <<<"$out" >/dev/null 2>&1; then
    alt=$(smartctl "${flags[@]}" -d sat "$dev" 2>/dev/null || true)
    if jq -e '.smart_status' <<<"$alt" >/dev/null 2>&1; then out=$alt; fi
  fi
  printf '%s' "$out"
}

# Findings, one per line: LEVEL <tab> text. Nothing printed = nothing to see.
findings_jq='
def attr(n): ((.ata_smart_attributes.table // []) | map(select(.id == n)) | .[0]);
def raw(n): (attr(n).raw.value // null);
def f(l; t): "\(l)\t\(t)";
def pos(n): (raw(n) as $v | if $v != null and $v > 0 then $v else null end);
(.nvme_smart_health_information_log // null) as $nv
| ((.ata_smart_self_test_log.standard.table // [])[0]) as $last
| [
    (if .smart_status.passed == false then f("BAD"; "the disk fails its own SMART assessment") else empty end),
    (pos(197) as $v | if $v then f("BAD"; "\($v) pending sector(s): spots the disk cannot read and has not remapped yet") else empty end),
    (pos(198) as $v | if $v then f("BAD"; "\($v) sector(s) that stay unreadable (offline uncorrectable)") else empty end),
    (if $last != null and $last.status.passed == false then f("BAD"; "the last self-test failed (\($last.status.string))") else empty end),
    (pos(5) as $v | if $v and ($v >= 100 or $v > ($base["5"] // 0)) then f(if $v >= 100 then "BAD" else "WATCH" end; "\($v) reallocated sector(s): the disk is already replacing worn spots") else empty end),
    (pos(187) as $v | if $v and $v > ($base["187"] // 0) then f("WATCH"; "\($v) uncorrectable read error(s) reported") else empty end),
    (pos(199) as $v | if $v and $v > ($base["199"] // 0) then f("WATCH"; "\($v) interface CRC error(s): usually a bad or loose SATA cable, not the disk") else empty end),
    ((.ata_smart_error_log.summary.count // 0) as $n | if $n > ($base["err"] // 0) then f("WATCH"; "the disk logged \($n) error(s) (smartctl -l error)") else empty end),
    (if $nv != null and ($nv.critical_warning // 0) > 0 then f("BAD"; "NVMe critical warning \($nv.critical_warning)") else empty end),
    (if $nv != null and ($nv.media_errors // 0) > 0 then f("WATCH"; "\($nv.media_errors) NVMe media error(s)") else empty end),
    (if $nv != null and ($nv.percentage_used // 0) >= 90 then f("WATCH"; "\($nv.percentage_used) % of the rated write endurance used") else empty end),
    ((attr(231) // attr(233) // attr(177)) as $w | if $w != null and ($w.value // 100) < 20 then f("WATCH"; "SSD wear indicator at \($w.value) of 100") else empty end),
    ((.power_on_time.hours // 0) as $h | if $h >= 43800 then f("WATCH"; "old: \($h) hours of use (\($h / 8766 | floor) years)") else empty end),
    ((.temperature.current // 0) as $t | if $t >= 55 then f("WATCH"; "hot: \($t) °C") else empty end)
  ] | .[]'

# Passed self-tests are kept in disk-tests (serial, lifetime hours, type, time, then the counters 5, 187, 199 and the error log count at that
# moment). The counter findings (reallocated, uncorrectable, CRC, error log) only count when they grew since the last passed test: an old
# error does not keep a disk at WATCH after a self-test came back clean. Age, heat and wear are not counters and stay. BAD never goes away.
tests_file=${HS_STATE_DIR:-/var/lib/hs}/disk-tests

record_test() {   # record_test <json>: remember the newest self-test when it passed and is not recorded yet
  local js=$1 serial row
  serial=$(jq -r '.serial_number // empty' <<<"$js" 2>/dev/null || true)
  row=$(jq -r '(.ata_smart_self_test_log.standard.table // [])[0] | select(. != null and .status.passed == true) | "\(.lifetime_hours)	\(.type.string)"' <<<"$js" 2>/dev/null || true)
  [ -n "$serial" ] && [ -n "$row" ] || return 0
  { mkdir -p "$(dirname "$tests_file")"
    if ! awk -F'	' -v s="$serial" -v r="$row" '($1 "	" $2 "	" $3) == (s "	" r) { f = 1 } END { exit !f }' "$tests_file" 2>/dev/null; then
      printf '%s	%s	%s	%s
' "$serial" "$row" "$(date +%s)" "$(jq -r '
        def raw(n): ((.ata_smart_attributes.table // []) | map(select(.id == n)) | .[0].raw.value) // 0;
        [raw(5), raw(187), raw(199), (.ata_smart_error_log.summary.count // 0)] | @tsv' <<<"$js")" >>"$tests_file"
    fi
  } 2>/dev/null || true
}

baseline_of() {   # baseline_of <json> -> {"5":n,"187":n,"199":n,"err":n} from the last passed test of this disk, {} when none or the newest test failed
  local js=$1 serial
  serial=$(jq -r '.serial_number // empty' <<<"$js" 2>/dev/null || true)
  if [ -z "$serial" ] || [ ! -f "$tests_file" ] ||
     [ "$(jq -r '(.ata_smart_self_test_log.standard.table // [])[0].status.passed' <<<"$js" 2>/dev/null)" = false ]; then echo '{}'; return; fi
  awk -F'	' -v s="$serial" '$1 == s { l = $0 } END { print l }' "$tests_file" |
    jq -Rc 'split("	") | if length >= 8 then {"5": (.[4]|tonumber), "187": (.[5]|tonumber), "199": (.[6]|tonumber), "err": (.[7]|tonumber)} else {} end' 2>/dev/null || echo '{}'
}

findings_of() {   # findings_of <json>
  record_test "$1"
  jq -r --argjson base "$(baseline_of "$1")" "$findings_jq" <<<"$1" 2>/dev/null || true
}

verdict_of() {   # stdin: findings -> OK | WATCH | BAD
  local f; f=$(cat)
  if grep -q '^BAD' <<<"$f"; then echo BAD; elif grep -q '^WATCH' <<<"$f"; then echo WATCH; else echo OK; fi
}

disks() {
  local name size rota
  while read -r name size rota; do
    [ "$size" -gt 0 ] || continue
    case "$name" in zd*|loop*|sr*|dm-*|ram*) continue ;; esac
    second_path "$name" && continue
    echo "$name $size $rota"
  done < <(lsblk -dnb -o NAME,SIZE,ROTA)
}

# Power state of a rotating disk without waking it (hdparm -C only asks the power mode): spinning | asleep | "-"
power_of() {   # power_of <name> <rota>
  local st
  [ "$2" = 1 ] && command -v hdparm >/dev/null 2>&1 || { echo -; return 0; }
  st=$(hdparm -C "/dev/$1" 2>/dev/null | awk -F: '/drive state is/ { gsub(/[ 	]/, "", $2); print $2 }' || true)
  case "$st" in
    active*|idle*) echo spinning ;;
    standby|sleeping) echo asleep ;;
    *) echo - ;;
  esac
}

list_rows() {   # name, size, kind, model, verdict, hours, first reason, power (spinning|asleep|-)
  local name size rota js model hours fnd v why kind
  while read -r name size rota; do
    js=$(smart_json "/dev/$name" standby)
    if [[ "$name" == nvme* ]]; then kind=NVMe; elif [ "$rota" = 1 ]; then kind=HDD; else kind=SSD; fi
    model=$(jq -r '.model_name // "-"' <<<"$js" 2>/dev/null || echo -)
    hours=$(jq -r '.power_on_time.hours // "-"' <<<"$js" 2>/dev/null || echo -)
    if jq -e '(.smartctl.messages // []) | map(.string) | join(" ") | test("STANDBY|SLEEP")' <<<"$js" >/dev/null 2>&1; then
      v=asleep; why="not read, the disk is asleep"
    elif ! jq -e '.smart_status' <<<"$js" >/dev/null 2>&1; then
      v=unknown; why="SMART not readable (USB bridge or card reader?)"
    else
      fnd=$(findings_of "$js")
      v=$(verdict_of <<<"$fnd")
      why=$(printf '%s\n' "$fnd" | sort | head -n1 | cut -f2)   # BAD sorts before WATCH
      [ -n "$why" ] || why="-"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$size" "$kind" "$model" "$v" "$hours" "$why" "$(power_of "$name" "$rota")"
  done < <(disks)
}

# One reading line per disk for the daily SMART check (state-db.py baseline-run), tab separated, 16 fields, never an empty one:
# name, state (read|asleep|unreadable), kind, serial, wwn, hours, realloc, pending, uncorr, crc, nv_crit, nv_media, nv_used, nv_spare,
# nv_spare_thr, model. Normal mode reads with -n standby (a sleeping disk stays asleep); with --wake <names> only those disks are
# read, without the standby flag (the weekly wake, docs/PLAN-disk-health.md decision 11).
readings_jq='
def attr(n): ((.ata_smart_attributes.table // []) | map(select(.id == n)) | .[0].raw.value) // null;
def v(x): if x == null then "-" else (x | tostring) end;
(.nvme_smart_health_information_log // null) as $nv
| [ v(.power_on_time.hours),
    v(attr(5) // .scsi_grown_defect_list), v(attr(197)), v(attr(198) // .scsi_error_counter_log.read.total_uncorrected_errors), v(attr(199)),
    v($nv.critical_warning), v($nv.media_errors), v($nv.percentage_used), v($nv.available_spare), v($nv.available_spare_threshold) ] | @tsv'

readings_rows() {
  local name size rota js kind serial state wwn vals model
  while read -r name size rota; do
    if [ -n "$wake" ]; then
      case ",$wake," in *",$name,"*) ;; *) continue ;; esac
      js=$(smart_json "/dev/$name")
    else
      js=$(smart_json "/dev/$name" standby)
    fi
    if [[ "$name" == nvme* ]]; then kind=NVMe; elif [ "$rota" = 1 ]; then kind=HDD; else kind=SSD; fi
    serial=$(jq -r '.serial_number // empty' <<<"$js" 2>/dev/null || true)
    [ -n "$serial" ] || serial=$(lsblk -dno SERIAL "/dev/$name" 2>/dev/null | awk 'NR == 1' || true)
    [ -n "$serial" ] || serial=-
    if jq -e '(.smartctl.messages // []) | map(.string) | join(" ") | test("STANDBY|SLEEP")' <<<"$js" >/dev/null 2>&1; then
      state=asleep
    elif ! jq -e '.smart_status' <<<"$js" >/dev/null 2>&1; then
      state=unreadable
    else
      state=read
    fi
    if [ "$state" = read ]; then
      wwn=$(jq -r 'if .wwn then "\(.wwn.naa)-\(.wwn.oui)-\(.wwn.id)" elif ((.nvme_namespaces // [])[0].eui64 // null) then (.nvme_namespaces[0].eui64 | "eui-\(.oui)-\(.ext_id)") else "-" end' <<<"$js")
      vals=$(jq -r "$readings_jq" <<<"$js")
      model=$(jq -r '(.model_name // .scsi_model_name // "-") | gsub("\t"; " ")' <<<"$js")
    else
      wwn=-; vals=$'-\t-\t-\t-\t-\t-\t-\t-\t-\t-'; model=-
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$state" "$kind" "$serial" "$wwn" "$vals" "$model"
  done < <(disks)
}

human() { numfmt --to=si --suffix=B "$1" 2>/dev/null || echo "$1"; }

detail() {
  local dev=$1 js fnd v
  js=$(smart_json "$dev")
  jq -e '.smart_status' <<<"$js" >/dev/null 2>&1 || fail "$(t '%s gives no SMART data (a card reader, or a USB case that hides it).' "$dev")"
  step "$dev: $(jq -r '.model_name // "unknown model"' <<<"$js")"
  jq -r '
    def attr(n): ((.ata_smart_attributes.table // []) | map(select(.id == n)) | .[0]);
    def raw(n): (attr(n).raw.value // "-");
    ["Serial", (.serial_number // "-")],
    ["Firmware", (.firmware_version // "-")],
    ["Size", ((.user_capacity.bytes // 0) / 1e9 | floor | tostring) + " GB"],
    ["Type", (if .rotation_rate then (if .rotation_rate == 0 then "SSD" else "HDD, \(.rotation_rate) rpm" end) elif .nvme_smart_health_information_log then "NVMe" else "-" end)],
    ["Powered on", ((.power_on_time.hours // 0) as $h | "\($h) hours (\(($h / 8766 * 10 | floor) / 10) years)")],
    ["Power cycles", ((.power_cycle_count // "-") | tostring)],
    ["Temperature", ((.temperature.current // "-") | tostring) + " °C"],
    ["SMART assessment", (if .smart_status.passed == true then "passed" else "FAILED" end)],
    (if .ata_smart_attributes then
      ["Reallocated sectors", (raw(5) | tostring)],
      ["Pending sectors", (raw(197) | tostring)],
      ["Offline uncorrectable", (raw(198) | tostring)],
      ["Interface CRC errors", (raw(199) | tostring)]
     else empty end),
    (.nvme_smart_health_information_log // empty | ["Endurance used", "\(.percentage_used) %"], ["Media errors", (.media_errors | tostring)], ["Spare left", "\(.available_spare) %"]),
    ["Error log entries", ((.ata_smart_error_log.summary.count // 0) | tostring)]
    | "\(.[0])\t\(.[1])"' <<<"$js" | kv_rows

  local tests
  tests=$(jq -r '(.ata_smart_self_test_log.standard.table // [])[:3][] | "\(.type.string)\t\(.status.string)\tat \(.lifetime_hours) h"' <<<"$js" 2>/dev/null || true)
  if [ -n "$tests" ]; then
    step "Last self-tests"; tr '\t' ' ' <<<"$tests" | while IFS= read -r l; do note "$l"; done
  else
    step "Last self-tests"; note "$(t 'No self-test has been run yet (start one: hs disk %s test short).' "$(basename "$dev")")"
  fi

  fnd=$(findings_of "$js")
  v=$(verdict_of <<<"$fnd")
  step "Verdict"
  if [ -n "$fnd" ]; then
    while IFS=$'\t' read -r lvl txt; do
      if [ "$lvl" = BAD ]; then warn "$(t 'BAD: %s' "$txt")"; else note "$(t 'watch: %s' "$txt")"; fi
    done < <(printf '%s\n' "$fnd" | sort)
  fi
  case "$v" in
    OK)    ok "$(t 'Verdict: OK. SMART shows nothing wrong. It does not prove the surface is fine: a long self-test reads all of it (hs disk %s test long).' "$(basename "$dev")")" ;;
    WATCH) warn "Verdict: WATCH. It works, but keep the notes above in mind, and keep a copy of anything that matters." ;;
    BAD)   fail "Verdict: BAD. Replace this disk (hs pool bulk replace, or take it out)." ;;
  esac
}

# label and value per line (tab separated on stdin) as kv rows; the labels here are longer than kv's default width
kv_rows() { local k v; while IFS=$'\t' read -r k v; do KV_WIDTH=22 kv "$k" "$v"; done; }

if $readings; then readings_rows; exit 0; fi

case "$action" in
  detail)
    if [ -z "$target" ]; then
      if $list; then list_rows; exit 0; fi
      step "Disks"
      { thead 'Disk' 'Size' 'Type' 'Model' 'Verdict' 'Hours' 'Note' 'Power'
        list_rows | awk -F'\t' -v OFS='\t' '{ cmd = "numfmt --to=si --suffix=B " $2; cmd | getline s; close(cmd); $2 = s; if ($8 == "spinning") $8 = sp; else if ($8 == "asleep") $8 = as; print }' sp="$(t spinning)" as="$(t asleep)"
      } | table
      note "Details of one disk: hs disk <disk> health   (WATCH and BAD are explained there)"
    else
      detail "$(resolve "$target")"
    fi ;;

  test)
    dev=$(resolve "$target")
    mounted=$(lsblk -nr -o MOUNTPOINT "$dev" | tr -d '\n')
    [ -z "$mounted" ] || note "$(t '%s is in use: the self-test runs inside the disk and does not change data, but it slows the disk while it runs.' "$dev")"
    if $dry; then echo "Would run: smartctl -t $kind $dev"; exit 0; fi
    js=$(smart_json "$dev")
    mins=$(jq -r --arg k "$kind" '(.ata_smart_data.self_test.polling_minutes[if $k == "long" then "extended" else "short" end]) // empty' <<<"$js" 2>/dev/null || true)
    if out=$(smartctl -t "$kind" "$dev" 2>&1); then
      if [ -n "$mins" ]; then ok "$(t 'Started the %s self-test on %s (about %s minutes).' "$kind" "$dev" "$mins")"
      else ok "$(t 'Started the %s self-test on %s.' "$kind" "$dev")"; fi
      note "$(t 'The disk does it by itself; nothing else to do. Check later: hs disk %s results' "$(basename "$dev")")"
    else
      printf '%s\n' "$out" | sed -n '/^===/,$p' | head -n 8 | trail
      fail "$(t 'The self-test did not start (one may be running already: hs disk %s results).' "$(basename "$dev")")"
    fi ;;

  results)
    dev=$(resolve "$target")
    js=$(smart_json "$dev")
    jq -e '.smart_status' <<<"$js" >/dev/null 2>&1 || fail "$(t '%s gives no SMART data.' "$dev")"
    record_test "$js"
    step "$(t 'Self-tests of %s' "$dev")"
    running=$(jq -r '.ata_smart_data.self_test.status.string // empty | select(test("progress"))' <<<"$js" 2>/dev/null || true)
    [ -z "$running" ] || note "$(t 'A test is running: %s' "$running")"
    jq -r '(.ata_smart_self_test_log.standard.table // [])[:8][] | "\(.type.string)\t\(.status.string)\tat \(.lifetime_hours) h"' <<<"$js" |
      tr '	' ' ' | while IFS= read -r l; do note "$l"; done || true
    if [ -z "$(jq -r '(.ata_smart_self_test_log.standard.table // [])[0] // empty' <<<"$js")" ]; then note "none yet"; fi ;;
esac
