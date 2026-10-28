#!/usr/bin/env bash
# help: change an instance without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: eine Instanz ändern, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start <instance> <start|stop|restart|snapshot|restore|delete-snapshot|add-storage|remove-storage|set|ip|update|update-all|delete|create> [--ram <MB|none>] [--cpu <N|none>] [--disk <GB>] [--autostart yes|no] [--docker yes|no] [--address <ip>] [--type container|docker|vm] [--profile <network profile>] [--bind <fast|shares|sensitive>:<name>:<path>[:ro] ...] [--snapshot <name>] [--label <name>] [--kind fast|shares|sensitive] [--name <storage>] [--path <inside>] [--readonly] [--as <uid>:<gid>] [--device <name>] [--confirm <word>]
# System command (hs sys ct plan|start): for the interface, timers and tests. It never asks and prints plain
# key<TAB>value lines like pool-change.sh. The questions of the console wizards are
# ct-guided.sh's; the plan is manage-ct.sh --dry-run sorted into lines.
#
# plan: exit 0 = allowed, 1 = refused, 2 = something is still missing. Output, in this order:
#   status<TAB>ok|refused|needs
#   needs<TAB><input>            (status needs: snapshot, kind, name, path, device; nothing else is printed)
#   reason<TAB><text>            (status refused)
#   heading|step|note|warn|danger|command<TAB><line>   (status ok)
#   confirm_name<TAB><instance>  only when the plan has a danger line (restore, delete-snapshot): it must be typed to start
#   long<TAB>no
# start: the same checks, then the work runs as a background job. Output: status<TAB>started and unit<TAB><job unit>.
# create: --profile puts the instance on the network (VLAN profile) of that name (hs sys ct profiles lists them); every --bind attaches storage once the
#   instance runs (kind:name:absolute path inside[:ro]); the job is `ct-change.sh apply-create`: manage-ct.sh --create, then --add-storage per bind. Bulk folders
#   cannot go into a VM.
# update-all: the instance argument is `all`; the plan is ct-update-all.sh --dry-run (the running containers, no VMs), the job updates exactly that list.
# Test knobs: HS_MANAGE_CT (stand-in for manage-ct.sh), HS_CT_UPDATE_ALL (stand-in for ct-update-all.sh), HS_CT_BINDINGS (stand-in for ct-bindings.sh), HS_INCUS.
set -euo pipefail
here=$(dirname "$0")
manage=${HS_MANAGE_CT:-$here/manage-ct.sh}
bindings=${HS_CT_BINDINGS:-$here/ct-bindings.sh}
updall=${HS_CT_UPDATE_ALL:-$here/ct-update-all.sh}

# the job of a create with bindings: create first, then bind the storage one by one, stop at the first failure
if [ "${1:-}" = apply-create ]; then
  shift
  cargs=(); binds=()
  while [ $# -gt 0 ]; do
    case "$1" in --bind) binds+=("${2:-}"); shift 2 ;; *) cargs+=("$1"); shift ;; esac
  done
  bash "$manage" "${cargs[@]}" || exit 1
  for b in ${binds[@]+"${binds[@]}"}; do
    bkind=${b%%:*}; rest=${b#*:}; bname=${rest%%:*}; rest=${rest#*:}; bpath=${rest%%:*}; bro=()
    [[ "$b" != *:ro ]] || bro=(--readonly)
    echo "bind $bkind $bname at $bpath"
    bash "$manage" "${cargs[1]}" --add-storage "$bkind" "$bname" "$bpath" ${bro[@]+"${bro[@]}"} || { echo "failed: $b" >&2; exit 1; }
  done
  exit 0
fi

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; ct=${2:-}; action=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: ct-change.sh plan|start <instance> <action> [options]" >&2; exit 1 ;; esac
[[ "$ct" =~ ^[a-z][a-z0-9-]*$ ]] || refuse "invalid instance name"
case "$action" in start|stop|restart|snapshot|restore|delete-snapshot|add-storage|remove-storage|set|ip|update|update-all|delete|create) ;; *) refuse "unknown action" ;; esac
[ "$action" != update-all ] || [ "$ct" = all ] || refuse "update-all is for all instances: use 'all' as the instance"
[ "$ct" != all ] || [ "$action" = update-all ] || refuse "'all' is only for update-all"
shift 3

snap="" label="" kind="" sname="" path="" as="" device="" confirm="" readonly=false
ram="" cpu="" disk="" autostart="" docker="" address="" type=container profile="" binds=()
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) snap=${2:-}; shift 2 ;;
    --label)    label=${2:-}; shift 2 ;;
    --kind)     kind=${2:-}; shift 2 ;;
    --name)     sname=${2:-}; shift 2 ;;
    --path)     path=${2:-}; shift 2 ;;
    --as)       as=${2:-}; shift 2 ;;
    --device)   device=${2:-}; shift 2 ;;
    --confirm)  confirm=${2:-}; shift 2 ;;
    --readonly) readonly=true; shift ;;
    --ram)       ram=${2:-}; shift 2 ;;
    --cpu)       cpu=${2:-}; shift 2 ;;
    --disk)      disk=${2:-}; shift 2 ;;
    --autostart) autostart=${2:-}; shift 2 ;;
    --docker)    docker=${2:-}; shift 2 ;;
    --address)   address=${2:-}; shift 2 ;;
    --type)      type=${2:-}; shift 2 ;;
    --profile)   profile=${2:-}; shift 2 ;;
    --bind)      binds+=("${2:-}"); shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
word='^[A-Za-z0-9][A-Za-z0-9._-]*$'
for v in "$snap" "$label" "$device" "$sname" "$profile"; do
  [ -z "$v" ] || [[ "$v" =~ $word ]] || refuse "invalid name '$v'"
done

needs=()
case "$action" in
  restore|delete-snapshot) [ -n "$snap" ] || needs+=(snapshot) ;;
  add-storage) [ -n "$kind" ] || needs+=(kind); [ -n "$sname" ] || needs+=(name); [ -n "$path" ] || needs+=(path) ;;
  remove-storage) [ -n "$device" ] || needs+=(device) ;;
  set) [ -n "$ram$cpu$disk$autostart$docker" ] || needs+=(setting) ;;
  ip) [ -n "$address" ] || needs+=(address) ;;
esac
for pair in "ram:$ram" "cpu:$cpu" "disk:$disk"; do
  v=${pair#*:}
  [ -z "$v" ] || [ "$v" = none ] || [[ "$v" =~ ^[0-9]+$ ]] || refuse "${pair%%:*} must be a number (or none), got '$v'"
done
for pair in "autostart:$autostart" "docker:$docker"; do
  v=${pair#*:}
  [ -z "$v" ] || [ "$v" = yes ] || [ "$v" = no ] || refuse "${pair%%:*} is yes or no"
done
case "$type" in container|docker|vm) ;; *) refuse "type is container, docker or vm" ;; esac
[ "$action" = create ] || [ -z "$profile" -a ${#binds[@]} -eq 0 ] || refuse "--profile and --bind belong to create"
seen=" "
for b in ${binds[@]+"${binds[@]}"}; do
  [[ "$b" =~ ^(fast|shares|sensitive):[A-Za-z0-9][A-Za-z0-9._-]*:/[A-Za-z0-9._/-]*(:ro)?$ && "$b" != *..* ]] || refuse "expected <fast|shares|sensitive>:<name>:<absolute path>[:ro], got '$b'"
  n=${b#*:}; n=${n%%:*}
  case "$seen" in *" $n "*) refuse "two bindings are called '$n'" ;; esac
  seen="$seen$n "
  [ "$type" != vm ] || [ "${b%%:*}" = fast ] || refuse "Bulk folders can't be passed into a VM this way. Mount the Samba share inside the VM instead."
done
if [ ${#needs[@]} -gt 0 ]; then
  echo "status	needs"
  printf 'needs\t%s\n' "${needs[@]}"
  exit 2
fi

# the command line of manage-ct.sh for this change
margs=("$ct")
case "$action" in
  start|stop|restart) margs+=("--$action") ;;
  snapshot)        margs+=(--snapshot); [ -z "$label" ] || margs+=("$label") ;;
  restore)         margs+=(--restore "$snap") ;;
  delete-snapshot) margs+=(--delete-snapshot "$snap") ;;
  remove-storage)  margs+=(--remove-storage "$device") ;;
  add-storage)
    margs+=(--add-storage "$kind" "$sname" "$path")
    ! $readonly || margs+=(--readonly)
    [ -z "$as" ] || margs+=(--as "$as") ;;
  set)
    margs+=(--set)
    [ -z "$ram" ] || margs+=("ram=$ram"); [ -z "$cpu" ] || margs+=("cpu=$cpu"); [ -z "$disk" ] || margs+=("disk=$disk")
    [ -z "$autostart" ] || margs+=("autostart=$autostart"); [ -z "$docker" ] || margs+=("docker=$docker") ;;
  ip)     margs+=(--set "ip=$address") ;;
  update) margs+=(--update) ;;
  update-all) margs=() ;;
  delete) margs+=(--delete) ;;
  create)
    margs=(--create "$ct")
    [ "$type" != vm ] || margs+=(--vm)
    [ "$type" != docker ] || margs+=(--docker)
    [ -z "$profile" ] || margs+=(--profile "$profile")
    [ -z "$ram" ] || margs+=(--ram "$ram"); [ -z "$cpu" ] || margs+=(--cpu "$cpu"); [ -z "$disk" ] || margs+=(--disk "$disk")
    [ -z "$address" ] || margs+=(--ip "$address") ;;
esac

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY
rc=0
runner=$manage; [ "$action" != update-all ] || runner=$updall
out=$(bash "$runner" "${margs[@]}" --dry-run </dev/null 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "status	refused"
  printf '%s\n' "$out" | awk 'NF { sub(/^[ \t]+/, ""); sub(/^✗ /, ""); print "reason\t" $0 }'
  exit 1
fi

# what makes the plan red: the work cannot be undone
danger=""
newer=$(grep -c 'newer snapshot' <<<"$out" || true)
case "$action" in
  restore) danger="'$ct' goes back to '$snap': everything it wrote since is lost."
           [ "${newer:-0}" -eq 0 ] || danger="$danger The $newer newer snapshot(s) are deleted." ;;
  delete-snapshot) danger="The snapshot '$snap' of '$ct' is deleted for good." ;;
  delete) danger="'$ct' is deleted with all its snapshots. The attached storage stays." ;;
esac
long=no
[ "$action" != update ] && [ "$action" != update-all ] || long=yes
# update-all: the running containers the dry run names (its notes under the first heading)
targets=()
if [ "$action" = update-all ]; then
  while IFS= read -r l; do targets+=("$l"); done < <(printf '%s\n' "$out" | awk '/^── /{ n++; next } n == 1 && NF { sub(/^[ \t]+/, ""); print }')
  [ "${#targets[@]}" -gt 0 ] || refuse "No running container to update."
fi

if [ "$verb" = start ]; then
  if [ -n "$danger" ] && [ "$confirm" != "$ct" ]; then refuse "type the name to confirm: $ct"; fi
  . "$here/lib/job.sh"
  jargs=("${margs[@]}")
  [ "$action" != update-all ] || jargs=(--yes "${targets[@]}")   # exactly the list of the plan
  [ "$action" != delete ] || jargs+=(--yes)   # the name was typed in the interface; a job cannot ask
  if [ "$action" = create ] && [ ${#binds[@]} -gt 0 ]; then
    for b in "${binds[@]}"; do jargs+=(--bind "$b"); done
    unit=$(hs_job "ct-$action-$ct" "hs ct $ct $action" -- bash "$(cd "$here" && pwd)/ct-change.sh" apply-create "${jargs[@]}") || refuse "the job could not be started"
  else
    unit=$(hs_job "ct-$action-$ct" "hs ct $ct $action" -- bash "$runner" "${jargs[@]}") || refuse "the job could not be started"
  fi
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

echo "status	ok"
case "$action" in
  start)   printf 'heading\tstart %s\nstep\tstart the instance\n' "$ct" ;;
  stop)    printf 'heading\tstop %s\nstep\tstop the instance\n' "$ct" ;;
  restart) printf 'heading\trestart %s\nstep\tstop and start the instance\n' "$ct" ;;
  snapshot) printf 'heading\tsnapshot of %s\nstep\tsave the disk of the instance as it is now\nnote\tAttached storage (shares, volumes) is not part of a snapshot.\n' "$ct" ;;
  restore) printf 'heading\trestore %s to %s\n' "$ct" "$snap"
           [ "${newer:-0}" -eq 0 ] || printf 'step\tdelete the %s newer snapshot(s)\n' "$newer"
           printf 'step\tgo back to the snapshot\nnote\tAttached storage (shares, volumes) is not part of a snapshot and stays as it is.\n' ;;
  delete-snapshot) printf 'heading\tdelete snapshot %s of %s\nstep\tdelete the snapshot\n' "$snap" "$ct" ;;
  add-storage) printf 'heading\tadd storage %s to %s\nstep\tattach %s (%s) at %s\n' "$sname" "$ct" "$sname" "$kind" "$path"
               case "$kind" in shares|sensitive) printf 'note\tA share that does not exist yet is created.\n' ;; esac ;;
  remove-storage) printf 'heading\tremove storage %s from %s\nstep\tdetach %s\nnote\tThe data stays where it is; only the connection goes.\n' "$device" "$ct" "$device" ;;
  set) printf 'heading\tchange the settings of %s\n' "$ct"
       [ -z "$ram" ] || printf 'step\tmemory limit: %s\n' "$([ "$ram" = none ] && echo none || echo "$ram MiB")"
       [ -z "$cpu" ] || printf 'step\tCPU limit: %s\n' "$cpu"
       [ -z "$disk" ] || printf 'step\tdisk size: %s GiB\nnote\tA disk can only grow.\n' "$disk"
       [ -z "$autostart" ] || printf 'step\tstart at boot: %s\n' "$autostart"
       [ -z "$docker" ] || printf 'step\tDocker support: %s\nnote\tRestart the instance for the Docker setting to take effect.\n' "$docker" ;;
  ip) printf 'heading\tfixed address for %s\nstep\treserve %s in UniFi and restart the instance\nnote\tThe instance restarts; its services are down for a moment.\n' "$ct" "$address" ;;
  update) printf 'heading\tupdate %s\nstep\tsnapshot the instance (the way back)\nstep\tupdate the software inside\nnote\tIf something breaks, restore the snapshot before-update-....\n' "$ct" ;;
  update-all) printf 'heading\tupdate all running instances (%s)\n' "${#targets[@]}"
              for c in "${targets[@]}"; do printf 'step\tsnapshot %s, then update the software inside\n' "$c"; done
              printf 'warn\tEvery instance is snapshotted first and its services restart while it updates. Virtual machines are left alone.\nnote\tIf something breaks, restore the snapshot before-update-.... of that instance.\n' ;;
  delete) printf 'heading\tdelete %s\nstep\tdelete the instance and its snapshots\nstep\tgive its address back in UniFi\nnote\tAttached storage stays where it is. Remove a Zoraxy rule that pointed to it by hand.\n' "$ct" ;;
  create) printf 'heading\tcreate %s (%s)\nstep\tcreate the instance and pin its MAC\nstep\tstart it\n' "$ct" "$type"
          [ -z "$profile" ] || printf 'note\tOn the network (profile) %s.\n' "$profile"
          if [ -n "$address" ]; then printf 'step\treserve %s in UniFi and restart\n' "$address"; else printf 'note\tNo fixed address yet: set one afterwards.\n'; fi
          for b in ${binds[@]+"${binds[@]}"}; do
            r=${b#*:}; bn=${r%%:*}; bp=${r#*:}; bp=${bp%%:*}
            printf 'step\tbind %s %s at %s%s\n' "${b%%:*}" "$bn" "$bp" "$([[ "$b" == *:ro ]] && echo ' (read only)')"
          done ;;
esac

# which services go down with a stop or restart
case "$action" in
  stop|restart)
    svc=$(bash "$manage" "$ct" --users 2>/dev/null | awk -F'\t' '{ print $1 }' | paste -sd, - | sed 's/,/, /g' || true)
    [ -z "$svc" ] || printf 'note\tServices that go down: %s\n' "$svc" ;;
  delete)
    n=$(bash "$bindings" "$ct" 2>/dev/null | awk -F'\t' '$12 != "-" { n++ } END { print n+0 }' || true)
    [ "${n:-0}" -eq 0 ] || printf 'warn\t%s storage binding(s) are shared with other instances; they lose nothing, but check them first.\n' "$n" ;;
  remove-storage)
    also=$(bash "$bindings" "$ct" 2>/dev/null | awk -F'\t' -v d="$device" '$1 == d { print $12 }' || true)
    if [ -n "$also" ] && [ "$also" != "-" ]; then printf 'warn\tAlso mounted in: %s\n' "$also"; fi ;;
esac

# the commands (the dry run prints them indented; a line in brackets is a remark)
printf '%s\n' "$out" | awk '
  /^[ \t]*\(/ { next }
  /^[ \t]+(incus|bash) / { sub(/^[ \t]+/, ""); sub(/[ \t]+\(.*$/, ""); print "command\t" $0 }'
if [ -n "$danger" ]; then
  printf 'danger\t%s\nconfirm_name\t%s\n' "$danger" "$ct"
fi
printf 'long\t%s\n' "$long"
exit 0
