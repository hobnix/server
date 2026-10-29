#!/usr/bin/env bash
# help: change a pool without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: einen Pool ändern, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start <pool> <add|adopt|replace|remove|convert|close|open> [--member <name>] [--disks <id,...>] [--role data|parity] [--fs ext4|xfs|btrfs] [--encrypt] [--discard] [--mode detach|vdev] [--drain] [--merge] [--chown] [--confirm <word>]
# System command (hs sys pool plan|start): for the interface, timers and tests. It never asks and prints plain
# key<TAB>value lines. The questions of the console wizards are
# manage-pool.sh's; both use the same code for the plan: this script runs manage-pool.sh --dry-run and sorts its lines.
#
# plan: exit 0 = allowed, 1 = refused, 2 = something is still missing. Output, in this order:
#   status<TAB>ok|refused|needs
#   needs<TAB><input>            (status needs: member, disks, role; nothing else is printed)
#   reason<TAB><text>            (status refused: one line of the refusal)
#   heading|step|note|warn|danger|command|section|text<TAB><line>   (status ok: the plan in the order it is printed)
#   confirm_name<TAB><word>      what must be typed to confirm (the disk for replace/remove/convert, else the pool)
#   long<TAB>yes|no              hours of work (SnapRAID replace/remove/convert)
#   option<TAB><name><TAB><values separated by |><TAB><default>     inputs that may still be given
# start: the same checks, then the work runs as a background job. It needs --confirm <word> equal to confirm_name.
#   With --encrypt the passphrase is the first line on standard input (it goes into a 0600 file that the job
#   reads and deletes, never into an argument). Output: status<TAB>started and unit<TAB><job unit>; exit codes as plan.
# Test knobs: HS_MANAGE_POOL (stand-in for manage-pool.sh), HS_BULK_TYPE_FILE, HS_RUN_DIR.
set -euo pipefail
here=$(dirname "$0")
manage=${HS_MANAGE_POOL:-$here/manage-pool.sh}

verb=${1:-}; pool=${2:-}; action=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: pool-change.sh plan|start <pool> <add|adopt|replace|remove|convert|close|open> [options]" >&2; exit 1 ;; esac
[[ "$pool" =~ ^[a-z][a-z0-9_-]*$ ]] || { printf 'status\trefused\nreason\tinvalid pool name\n'; exit 1; }
case "$action" in add|adopt|replace|remove|convert|close|open) ;; *) printf 'status\trefused\nreason\tunknown action (add, adopt, replace, remove, convert, close or open)\n'; exit 1 ;; esac
shift 3

member="" disks="" role="" fs="" mode="" confirm="" encrypt=false merge=false chown=false drain=false discard=false
while [ $# -gt 0 ]; do
  case "$1" in
    --member)  member=${2:-}; shift 2 ;;
    --disks)   disks=${2:-}; shift 2 ;;
    --role)    role=${2:-}; shift 2 ;;
    --fs)      fs=${2:-}; shift 2 ;;
    --mode)    mode=${2:-}; shift 2 ;;
    --confirm) confirm=${2:-}; shift 2 ;;
    --encrypt) encrypt=true; shift ;;
    --merge)   merge=true; shift ;;
    --drain)   drain=true; shift ;;
    --discard) discard=true; shift ;;
    --chown)  chown=true; shift ;;
    *) printf 'status\trefused\nreason\tunknown option %s\n' "$1"; exit 1 ;;
  esac
done
[ "$action" != adopt ] || role=adopt

bulk_type=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || echo zfs)
snapraid=false; { [ "$pool" = bulk ] && [ "$bulk_type" = snapraid ]; } && snapraid=true

# What is still missing (only what nobody else can decide: the choices with a default are options below)
needs=()
case "$action" in
  add|adopt) [ -n "$disks" ] || needs+=(disks)
             if [ "$action" = add ] && $snapraid && [ -z "$role" ]; then needs+=(role); fi ;;
  replace)   [ -n "$member" ] || needs+=(member); [ -n "$disks" ] || needs+=(disks) ;;
  remove|convert|close|open) [ -n "$member" ] || needs+=(member) ;;
esac
if [ ${#needs[@]} -gt 0 ]; then
  echo "status	needs"
  printf 'needs\t%s\n' "${needs[@]}"
  exit 2
fi

# The command line of manage-pool.sh for this change
args=("$pool")
case "$action" in
  add|adopt) args+=(--disks "$disks"); [ -z "$role" ] || args+=(--role "$role") ;;
  replace)   args+=(--replace "$member" --disks "$disks") ;;
  remove)    args+=(--remove "$member"); [ -z "$mode" ] || args+=(--mode "$mode") ;;
  convert)   args+=(--convert "$member"); ! $discard || args+=(--discard) ;;
  close)     args+=(--close "$member"); ! $drain || args+=(--drain) ;;
  open)      args+=(--open "$member") ;;
esac
[ -z "$fs" ] || args+=(--fs "$fs")
! $encrypt || args+=(--encrypt)
! $merge || args+=(--merge)
! $chown || args+=(--chown)

# the plan: the dry run of the wizard's own script, no terminal, plain text
export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY HS_DISK_PASSPHRASE_FILE
rc=0
out=$(bash "$manage" "${args[@]}" --dry-run </dev/null 2>&1) || rc=$?

if [ "$rc" -ne 0 ]; then
  echo "status	refused"
  # a refusal is one or two lines ("Not possible: ..."); anything else the script said stays as it is
  printf '%s\n' "$out" | awk 'NF { sub(/^[ \t]+/, ""); print "reason\t" $0 }'
  exit 1
fi

confirm_name=$pool; [ -z "$member" ] || confirm_name=$member
# close (without --drain) and open change a mark only: nothing moves, nothing is erased, so no word to type
needs_word=true; { [ "$action" = open ] || { [ "$action" = close ] && ! $drain; }; } && needs_word=false
long=no
{ $snapraid && case "$action" in replace|remove|convert) true ;; close) $drain ;; *) false ;; esac; } && long=yes

if [ "$verb" = start ]; then
  if $needs_word && [ "$confirm" != "$confirm_name" ]; then
    printf 'status\trefused\nreason\ttype the name to confirm: %s\n' "$confirm_name"
    exit 1
  fi
  passfile=""
  if $encrypt; then
    IFS= read -r pass || pass=""
    [ -n "$pass" ] || { printf 'status\trefused\nreason\tno passphrase on standard input\n'; exit 1; }
    run_dir=${HS_RUN_DIR:-/run/hs}
    mkdir -p "$run_dir"; chmod 700 "$run_dir"
    passfile=$(mktemp "$run_dir/job-pass.XXXXXX")
    printf %s "$pass" > "$passfile"
  fi
  . "$here/lib/job.sh"
  unit=$(HS_DISK_PASSPHRASE_FILE=$passfile hs_job "pool-$action-${member:-$pool}" "hs pool $pool $action ${member:-}" -- \
    bash "$manage" "${args[@]}" --yes) || { [ -z "$passfile" ] || rm -f "$passfile"; printf 'status\trefused\nreason\tthe job could not be started\n'; exit 1; }
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

echo "status	ok"
printf '%s\n' "$out" | awk '
  /^Dry run:/ { next }
  /^[ \t]*$/ { next }
  /^Plan: /          { sub(/^Plan: /, ""); print "heading\t" $0; next }
  /^Plan:$/          { print "section\tPlan"; next }
  /^Current array:/  { print "section\tCurrent array"; next }
  /^Command:$/       { want = 1; next }
  want               { sub(/^[ \t]+/, ""); print "command\t" $0; want = 0; next }
  /^Note: /          { sub(/^Note: /, ""); print "note\t" $0; next }
  /^WARNING: /       { sub(/^WARNING: /, ""); print "warn\t" $0; next }
  /^ALL DATA/        { print "danger\t" $0; next }
  /^[ \t]*[0-9]+\. / { sub(/^[ \t]*[0-9]+\. /, ""); print "step\t" $0; next }
  { sub(/^[ \t]+/, ""); print "text\t" $0 }'
# The disks that get formatted: what is on them (the notes of the free-disk list), and a danger line when the plan has none
# (the dry run of adding disks says nothing about the erase; the console asks for it after the plan).
if [ -n "$disks" ] && [ "$action" != adopt ]; then
  list=$(bash "$manage" --list-disks </dev/null 2>/dev/null || true)
  has_danger=false; grep -q '^ALL DATA' <<<"$out" && has_danger=true
  IFS=',' read -r -a ids <<<"$disks"
  for id in "${ids[@]}"; do
    notes=$(awk -F'\t' -v i="$id" '$1 == i { print $4 }' <<<"$list" | grep -o '\[[^]]*\]' | tr -d '[]' | paste -sd';' | sed 's/;/, /g' || true)
    [ -z "$notes" ] || printf 'warn\t%s is not empty: %s\n' "$id" "$notes"
    # the danger line: always for a disk that gets formatted (a plan that has one for this disk already keeps it)
    if ! { $has_danger && grep -q "^ALL DATA on $id" <<<"$out"; }; then printf 'danger\tALL DATA on %s will be erased.\n' "$id"; fi
  done
fi
! $needs_word || printf 'confirm_name\t%s\n' "$confirm_name"
printf 'long\t%s\n' "$long"
case "$action" in
  add|replace|convert)
    if $snapraid; then printf 'option\tfilesystem\text4|xfs|btrfs\text4\n'; fi
    printf 'option\tencrypt\tno|yes\tno\n' ;;
  close) if $snapraid && ! $drain; then printf 'option\tdrain\tno|yes\tno\n'; fi ;;
  adopt) printf 'option\tmerge\tno|yes\tno\noption\tchown\tno|yes\tno\n' ;;
  remove) if $snapraid; then case "$member" in parity*|*-parity*) ;; *) printf 'option\tmode\tmove|nomove\tmove\n' ;; esac; else printf 'option\tmode\tdetach|vdev\tdetach\n'; fi ;;
esac
exit 0
