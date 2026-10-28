#!/usr/bin/env bash
# help: snapshot and update the software in every running container, one after the other, with a report
# help.de: von jedem laufenden Container einen Schnappschuss machen und die Software darin aktualisieren, mit Bericht
# args: [<container>...] [--dry-run] [--yes] [--background|--foreground] [--include-vms] [--skip <container>]
# For every RUNNING container: what `hs ct <ct> update` does (manage-ct.sh --update: Incus snapshot
# before-update-<date>, then the container's own updater or apt full-upgrade). A failure does not stop the
# others. At the end a table shows result and snapshot, and the way back: hs ct <ct> restore <snapshot>.
# Virtual machines (the domain controller) are left alone unless --include-vms: update those by hand.
# On a terminal it asks once; then, unless --foreground, whether to run it as a background job (it can take
# long): hs job follow <unit>. A job (HS_CALLER set) and --yes ask nothing. --dry-run changes nothing and
# shows the commands manage-ct.sh would run. Exit code 1 when a container failed.
# Stand-ins for tests: HS_INCUS, HS_MANAGE_CT, HS_GUIDED_TTY=1 (there is a terminal; answers on stdin).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"
mct=${HS_MANAGE_CT:-$here/manage-ct.sh}
incus=${HS_INCUS:-incus}

usage() {
  say "usage: hs ct update-all [<container>...] [--dry-run] [--yes] [--background|--foreground] [--include-vms] [--skip <container>]"
  exit 1
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

dry=false; yes=false; bg=ask; vms=false; skip=" "; names=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=true; shift ;;
    --yes) yes=true; shift ;;
    --background) bg=yes; shift ;;
    --foreground) bg=no; shift ;;
    --include-vms) vms=true; shift ;;
    --skip) [ $# -ge 2 ] || usage; skip="$skip$2 "; shift 2 ;;
    -*) usage ;;
    *) names+=("$1"); shift ;;
  esac
done

snaps() {   # snaps <ct>: names of its snapshots
  "$incus" snapshot list "$1" -f csv -c n 2>/dev/null | sed 's|.*/||' | sort || true
}

# running instances: name,state,type
targets=()
while IFS=, read -r name state type _; do
  [ -n "$name" ] || continue
  [ "$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')" = RUNNING ] || continue
  case "$(printf '%s' "$type" | tr '[:lower:]' '[:upper:]')" in
    VIRTUAL-MACHINE|VM) $vms || { [ "${#names[@]}" -gt 0 ] || continue; } ;;
  esac
  case "$skip" in *" $name "*) continue ;; esac
  if [ "${#names[@]}" -gt 0 ]; then
    m=false; for n in "${names[@]}"; do [ "$n" != "$name" ] || m=true; done
    $m || continue
  fi
  targets+=("$name")
done < <("$incus" list -f csv -c n,s,t 2>/dev/null || true)

if [ "${#targets[@]}" -eq 0 ]; then
  note "No running container to update."
  exit 0
fi

step "$(t 'Containers to update: %s' "${#targets[@]}")"
for c in "${targets[@]}"; do note "$c"; done

if $dry; then
  for c in "${targets[@]}"; do
    step "$c"
    bash "$mct" "$c" --update --dry-run 2>&1 | trail || true
  done
  note "Dry run: nothing was changed."
  exit 0
fi

if ! $yes && [ -z "${HS_CALLER:-}" ]; then
  interactive || fail "Nothing is changed without --yes when there is no terminal."
  warn "This can take long. Every container gets a snapshot first; files on attached shares and volumes are not part of it."
  confirm "Update these containers now?" || fail "cancelled"
fi

if [ -z "${HS_CALLER:-}" ] && [ "$bg" != no ]; then
  if [ "$bg" = ask ] && interactive && confirm "Run it as a background job (you can close the terminal)?"; then bg=yes; fi
  if [ "$bg" = yes ]; then
    . "$here/lib/job.sh"
    args=(--yes)
    $vms && args+=(--include-vms)
    for c in "${targets[@]}"; do args+=("$c"); done   # the job updates exactly this list
    unit=$(hs_job ct-update-all "hs ct update-all" -- bash "$(cd "$here" && pwd)/ct-update-all.sh" "${args[@]}") || exit 1
    ok "$(t 'Started as job %s.' "$unit")"
    next_step "hs job follow $unit"
    exit 0
  fi
fi

report=""; failed=0; i=0
for c in "${targets[@]}"; do
  i=$((i + 1))
  before=$(snaps "$c")
  start=$SECONDS; rc=0
  SPIN_STREAM=1 SPIN_TAIL=15 spin "$(t 'Updating %s (%s of %s)' "$c" "$i" "${#targets[@]}")" bash "$mct" "$c" --update || rc=$?
  after=$(snaps "$c")
  snap=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tail -n1)
  if [ "$rc" -eq 0 ]; then res=ok; else res=FAILED; failed=$((failed + 1)); fi
  report+="$c"$'\t'"$res"$'\t'"${snap:--}"$'\t'"$((SECONDS - start))s"$'\n'
done

step "$(t 'Result')"
if [ "$failed" -gt 0 ]; then status_line "Failed" "$(t '%s of %s' "$failed" "${#targets[@]}")" bad
else status_line "Updated" "$(t '%s of %s' "${#targets[@]}" "${#targets[@]}")" ok; fi
{
  thead 'Container' 'Result' 'Snapshot' 'Time'
  printf '%s' "$report"
} | table
if [ "$failed" -gt 0 ]; then
  warn "$(t '%s of %s containers failed. The way back for each:' "$failed" "${#targets[@]}")"
  while IFS=$'\t' read -r c res snap _; do
    [ "$res" = FAILED ] || continue
    if [ "$snap" = "-" ]; then note "$(t '%s: no snapshot was made, nothing was changed before the failure' "$c")"
    else note "hs ct $c restore $snap"; fi
  done <<<"$report"
else
  ok "$(t 'All containers are updated.')"
fi
elapsed_line
note "$(t 'If a container misbehaves later: hs ct <name> restore <snapshot> (the snapshots are in the table).')"
[ "$failed" -eq 0 ]
