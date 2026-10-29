#!/usr/bin/env bash
# help: file manager backend (two panes): locations, listings, and copy/move/delete/rename/new folder as plan + background job
# help.de: Dateimanager-Backend (zwei Fenster): Orte, Listen, und Kopieren/Verschieben/Löschen/Umbenennen/Neuer Ordner als Plan + Hintergrundjob
# args: locations | pair <a> <b> | ls <loc> [--path P] [--cursor C] [--limit N] | plan|start <op> --from <loc> --path P [--to <loc> --to-path Q] [--conflict ...] [--verify ...] [--parity-after] [--newname N] [--conflicts] [--confirm T] | progress <unit>
#
# docs/PLAN-file-manager.md. The interface reads and changes only through `hs sys fm ...`; every rule below is enforced HERE, never only in the UI.
#
#   locations             status ok, then loc<TAB>id<TAB>kind<TAB>label<TAB>fs<TAB>size_bytes<TAB>free_bytes<TAB>writable<TAB>reason<TAB>pool<TAB>disk
#                         ids: disk:data-NN pool:bulk pool:fast cache:bulk share:<name> temp:<name>   (storage locked: status ok + locked<TAB>yes and no loc rows)
#   pair <a> <b>          status ok | status refused + reason (the same-files rule: a pool disk and the pool view of its array are never both sides)
#   ls <loc> [--path P] [--cursor C] [--limit N]
#                         status ok, row<TAB>type(d|f|l)<TAB>bytes<TAB>mtime<TAB>name<TAB>disks<TAB>flags<TAB>busy, then cursor<TAB>X or end. Folders first, then by name.
#                         The cursor is an offset into that order. Bytes of a folder are 0 (sizes of folders are not measured here).
#   plan <op> ...         op = copy|move|delete|rename|mkdir. The selection (names below --path) arrives on stdin, NUL separated. Key<TAB>value lines:
#                         status ok|refused, reason, heading, step, note, warn, files, folders, bytes, free_after, conflicts, parity, confirm_name, long
#                         (+ conflict<TAB>path<TAB>src_bytes<TAB>dst_bytes<TAB>src_mtime<TAB>dst_mtime with --conflicts)
#   start <op> ...        the same arguments and stdin; starts a background job: status done + unit. delete and an overwrite choice need --confirm <confirm_name>.
#   progress <unit>       the job's state: files_done files_total bytes_done bytes_total speed eta current phase result(running|done|cancelled|failed) skipped failed
#                         (+ skip/fail rows). Cancel = `hs sys jobs stop <unit>`: copied files stay, nothing unverified is removed.
#
# Tested with folders standing in for the locations (HS_FM_TEST=1, tests/fm.sh); NOT yet on real mergerfs / ZFS (docs/PLAN-file-manager.md section 7).
# Test knobs: HS_FM_TEST, HS_FM_DIR, HS_FM_SYNC=1 (start runs the job in the foreground), HS_FM_NO_RENAME=1 (folders on one filesystem stand in for disks: copy+verify, no rename), HS_FM_MARGIN (bytes), HS_FM_PARITY_CMD, HS_FM_POOL_ROOT, HS_FM_CACHE_ROOT,
# HS_FM_FAST_ROOT, HS_FM_TEMP_ROOT, HS_FM_ZFS_ROOT, HS_BULK_TYPE_FILE, HS_STATE_DIR, HS_DISKS_ROOT, HS_DETACHED_ROOT, HS_LOCK, HS_LOCK_ADMIN, HS_CAPABILITIES_FILE.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)   # absolute: the background job runs from another folder
. "$here/lib/fm.sh"
. "$here/lib/capability.sh"
. "$here/lib/bulklock.sh"
. "$here/lib/setting.sh"

# The safety switch (runtime setting fileManagerWrite, default off): this code has never run on real disks. Browsing, pairs and plans work either way.
write_on() { [ "$(setting_get fileManagerWrite 2>/dev/null || true)" = true ]; }
WRITE_OFF_REASON="The file manager is read only until you allow it: hs config set fileManagerWrite true (web: Settings, 'Allow the file manager to copy, move and delete files'). Test it in a VM first (docs/PLAN-file-manager.md)."
refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }
gate() { capability_on storage || refuse "The file manager needs the capability 'storage' (role homeserver)."; }
grab() { local p=$1 v; for v in ID KIND LABEL ROOT FS SIZE FREE ADD MOD REASON POOL DISK USABLE ERR AK REL TOP SNAP LOCK; do eval "$p$v=\"\${L$v}\""; done; }
sanitize_confirm() { local s; s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._ -' '_'); printf '%s\n' "${s:0:64}"; }

verb=${1:-}
case "$verb" in locations|pair|ls|plan|start|progress) shift ;; *) echo "usage: fm.sh locations|pair|ls|plan|start|progress ..." >&2; exit 1 ;; esac

# ======================================================================= locations
cmd_locations() {
  gate
  if storage_locked; then printf 'status\tok\nlocked\tyes\n'; return 0; fi
  echo "status	ok"
  if write_on; then printf 'write\tyes\n'; else printf 'write\tno\n'; fi
  local ids=() d n bt; bt=$(fm_bulk_type)
  if [ "$bt" = snapraid ]; then
    local m; local -A seen=()
    for d in "$(disks_root)"/data-[0-9]* "${HS_DETACHED_ROOT:-/mnt/bulk}"/data-[0-9]* "$fm_state_dir"/recovering/data-[0-9]*; do
      [ -e "$d" ] || continue
      m=${d##*/}; [[ $m =~ ^data-[0-9]+$ ]] || continue
      [ -z "${seen[$m]:-}" ] || continue
      seen[$m]=1; ids+=("disk:$m")
    done
  fi
  ids+=("pool:bulk")
  fm_ismnt "$(fm_fast_root)" && ids+=("pool:fast") || true
  [ "$bt" != snapraid ] || { fm_ismnt "$(fm_cache_root)" && ids+=("cache:bulk") || true; }
  local pr; if [ "$bt" = snapraid ]; then pr=$(fm_pool_root); else pr=$(fm_zfs_root); fi
  if fm_ismnt "$pr"; then
    for d in "$pr"/shares/*/ "$pr"/sensitive/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d"); [[ $n =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || continue
      case " ${ids[*]} " in *" share:$n "*) continue ;; esac
      ids+=("share:$n")
    done
  fi
  for d in "$(fm_temp_root)"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d"); [[ $n =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || continue
    fm_ismnt "${d%/}" && ids+=("temp:$n") || true
  done
  local id w r m
  for id in "${ids[@]}"; do
    fm_resolve "$id" || continue
    w=$LADD; m=$LMOD; r=$LREASON
    [ "$LUSABLE" = yes ] || { w=no; m=no; [ "$r" != - ] || r=$LERR; }
    [ "$w" = yes ] && r=-
    r=${r//$'\t'/ }
    printf 'loc\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$LKIND" "$LLABEL" "$LFS" "$LSIZE" "$LFREE" "$w" "$r" "$LPOOL" "$LDISK" "$m"
  done
}

cmd_pair() {
  gate
  [ $# -eq 2 ] || refuse "usage: pair <left-id> <right-id>"
  fm_resolve "$1" || refuse "$LERR"
  fm_resolve "$2" || refuse "$LERR"
  local why
  if why=$(fm_same_files "$1" "$2"); then refuse "$why"; fi
  echo "status	ok"
}

# ======================================================================= ls
declare -A busy_of=() busy_par=()
load_busy() {   # load_busy <array key>: items of live jobs
  local f pid line k a rel op pct tag
  for f in "$fm_dir"/busy/*; do
    [ -f "$f" ] || continue
    pid=$(awk -F'\t' '$1 == "pid" { print $2; exit }' "$f" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    while IFS=$'\t' read -r tag k rel op pct; do
      [ "$tag" = item ] && [ "$k" = "$1" ] || continue
      busy_of[$rel]="$op:$pct"
      a=$rel
      while [[ $a == */* ]]; do a=${a%/*}; busy_par[$a]=1; done
    done < "$f"
  done
}

cmd_ls() {
  gate
  [ $# -ge 1 ] || refuse "usage: ls <location>"
  local loc=$1 path="" cursor=0 limit=500; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --path)   [ $# -ge 2 ] || refuse "--path needs a value"; path=$2; shift 2 ;;
      --cursor) [ $# -ge 2 ] || refuse "--cursor needs a value"; cursor=$2; shift 2 ;;
      --limit)  [ $# -ge 2 ] || refuse "--limit needs a value"; limit=$2; shift 2 ;;
      *) refuse "unknown option $1" ;;
    esac
  done
  [[ $cursor =~ ^[0-9]{1,9}$ ]] || refuse "the cursor is a number"
  [[ $limit =~ ^[0-9]{1,5}$ ]] && [ "$limit" -ge 1 ] || refuse "the limit is a number from 1"
  [ "$limit" -le 2000 ] || limit=2000
  fm_resolve "$loc" || refuse "$LERR"
  [ "$LUSABLE" = yes ] || refuse "$LERR"
  local p dir real rel top
  p=$(fm_clean_path "$path") || refuse "the path must not contain .. , empty parts or control characters"
  dir=$LROOT${p:+/$p}
  [ -d "$dir" ] || refuse "no such folder"
  real=$(readlink -f -- "$dir")
  case "$real/" in "$LROOT"/*) ;; *) refuse "that path leaves the location" ;; esac
  rel=${real#"$LROOT"}; rel=${rel#/}
  if [ -n "$rel" ]; then
    top=${rel%%/*}
    fm_protected "" "$top"
    [ "$PROT" != system ] || refuse "$top belongs to the array and cannot be opened"
  fi
  load_busy "$LAK"
  local -a dlist=()
  if [ "$LKIND" = pool ] || [ "$LKIND" = share ]; then
    if [ "$LSNAP" = yes ]; then
      local dd; for dd in "$(disks_root)"/data-[0-9]*; do [ -d "$dd" ] && dlist+=("$dd") || true; done
    fi
  fi
  echo "status	ok"
  local fmt='%y\001%s\001%T@\001%f\0' y s t name n=0 more=no
  while IFS=$'\001' read -r -d '' y s t name; do
    n=$((n + 1))
    if [ "$n" -gt "$limit" ]; then more=yes; break; fi
    local shown=$name flags=() typ bytes disks="" a e full
    full=$real/$name
    if fm_badname "$name"; then shown=$(fm_esc "$name"); flags+=(badname); fi
    case $y in d) typ=d; bytes=0 ;; l) typ=l; bytes=$s; flags+=(link) ;; f) typ=f; bytes=$s ;; *) typ=f; bytes=0; flags+=(system) ;; esac
    fm_protected "$rel" "$name"
    [ -z "$PROT" ] || flags+=("$PROT")
    if [ "$typ" = d ]; then [ -r "$full" ] && [ -x "$full" ] || flags+=(noaccess)
    elif [ "$typ" = f ]; then [ -r "$full" ] || flags+=(noaccess); fi
    fm_arel "${rel:+$rel/}$name"; a=$AREL
    if [ "${#dlist[@]}" -gt 0 ]; then
      for e in "${dlist[@]}"; do
        if [ -e "$e/$a" ] || [ -L "$e/$a" ]; then disks=${disks:+$disks,}${e##*/}; fi
      done
    fi
    local b="-"; [ -z "${busy_of[$a]:-}" ] || b=${busy_of[$a]}
    [ -z "${busy_par[$a]:-}" ] || flags+=(busyparent)
    local fl="-"; [ "${#flags[@]}" -eq 0 ] || fl=$(IFS=,; echo "${flags[*]}")
    printf 'row\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$typ" "$bytes" "${t%.*}" "$shown" "${disks:--}" "$fl" "$b"
  done < <( { find -P "$real" -mindepth 1 -maxdepth 1 -type d -printf "$fmt" 2>/dev/null | LC_ALL=C sort -z -t $'\001' -k4
              find -P "$real" -mindepth 1 -maxdepth 1 ! -type d -printf "$fmt" 2>/dev/null | LC_ALL=C sort -z -t $'\001' -k4
            } | tail -z -n +$((cursor + 1)) )
  if [ "$more" = yes ]; then printf 'cursor\t%s\n' "$((cursor + limit))"; else echo end; fi
}

# ======================================================================= plan / start
op="" from="" path="" to="" topath="" policy=skip verify=size parity_after=no newname="" want_conflicts=no confirm="" now=no selfile="" jobid="" by=""
parse_args() {
  op=${1:-}; [ $# -eq 0 ] || shift
  case "$op" in copy|move|delete|rename|mkdir) ;; *) refuse "unknown operation '$op' (copy, move, delete, rename, mkdir)" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)      [ $# -ge 2 ] || refuse "--from needs a value"; from=$2; shift 2 ;;
      --path)      [ $# -ge 2 ] || refuse "--path needs a value"; path=$2; shift 2 ;;
      --to)        [ $# -ge 2 ] || refuse "--to needs a value"; to=$2; shift 2 ;;
      --to-path)   [ $# -ge 2 ] || refuse "--to-path needs a value"; topath=$2; shift 2 ;;
      --conflict)  [ $# -ge 2 ] || refuse "--conflict needs a value"; policy=$2; shift 2 ;;
      --verify)    [ $# -ge 2 ] || refuse "--verify needs a value"; verify=$2; shift 2 ;;
      --newname)   [ $# -ge 2 ] || refuse "--newname needs a value"; newname=$2; shift 2 ;;
      --confirm)   [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
      --by)        [ $# -ge 2 ] || refuse "--by needs a value"; by=$2; shift 2 ;;
      --job-id)    [ $# -ge 2 ] || refuse "--job-id needs a value"; jobid=$2; shift 2 ;;
      --sel-file)  [ $# -ge 2 ] || refuse "--sel-file needs a value"; selfile=$2; shift 2 ;;
      --parity-after) parity_after=yes; shift ;;
      --conflicts) want_conflicts=yes; shift ;;
      --now)       now=yes; shift ;;
      *) refuse "unknown option $1" ;;
    esac
  done
  case "$policy" in skip|rename|newer|overwrite) ;; *) refuse "--conflict is skip, rename, newer or overwrite" ;; esac
  case "$verify" in size|checksum) ;; *) refuse "--verify is size or checksum" ;; esac
  [ -n "$from" ] || refuse "--from <location> is needed"
  by=$(printf '%s' "${by:-${HS_USER:-}}" | tr -c 'A-Za-z0-9._@-' '_')
  [ -n "$by" ] || by=${HS_CALLER:-$(id -un)}
  [[ ${jobid:-x} =~ ^[A-Za-z0-9._-]{1,60}$ ]] || refuse "bad job id"
}

valid_newname() {   # a single new name: no slash, no control characters, not . or ..
  local n=$1
  [ -n "$n" ] && [ "${#n}" -le 255 ] || return 1
  case "$n" in */*|.|..|.hs-fm-partial.*) return 1 ;; esac
  fm_badname "$n" && return 1
  return 0
}

SEL=()
read_selection() {
  local nm src=/dev/stdin
  if [ -n "$selfile" ]; then
    case "$selfile" in "$fm_dir"/jobs/*.sel) ;; *) refuse "bad selection file" ;; esac
    [ -f "$selfile" ] || refuse "the selection is gone"
    src=$selfile
  elif [ -t 0 ]; then refuse "the selection comes on stdin, NUL separated"; fi
  while IFS= read -r -d '' nm || [ -n "$nm" ]; do
    [ -n "$nm" ] || refuse "an empty name in the selection"
    case "$nm" in */*) refuse "'$nm': names in the selection are relative to --path and hold no slash" ;; .|..) refuse "'$nm' is not a name" ;; esac
    [ "${#nm}" -le 255 ] || refuse "a name in the selection is too long"
    if fm_badname "$nm"; then refuse "'$(fm_esc "$nm")' has control characters or is not valid UTF-8: it cannot be selected here"; fi
    SEL+=("$nm")
  done < "$src"
  [ "${#SEL[@]}" -le 200000 ] || refuse "too many items in one selection"
  # duplicates
  if [ "${#SEL[@]}" -gt 1 ]; then
    local dups; dups=$(printf '%s\0' "${SEL[@]}" | LC_ALL=C sort -z | uniq -zd | head -z -n1 | tr '\0' ' ') || true
    [ -z "$dups" ] || refuse "'${dups% }' is selected twice"
  fi
}

fm_scan() {   # fm_scan <timeout> <path>...: sets S_FILES S_DIRS S_BYTES S_LINKS S_OTHER S_PARTIAL
  local to=$1 out; shift
  S_FILES=0; S_DIRS=0; S_BYTES=0; S_LINKS=0; S_OTHER=0; S_PARTIAL=no
  out=$( { timeout "$to" find -P "$@" -xdev -printf '%y\t%s\n' 2>/dev/null; echo "RC:$?"; } | awk -F'\t' '
    /^RC:/ { rc = substr($0, 4); next }
    $1 == "f" { f++; b += $2; next }
    $1 == "d" { d++; next }
    $1 == "l" { l++; next }
    { o++ }
    END { printf "%.0f %.0f %.0f %.0f %.0f %.0f\n", f, d, b, l, o, rc }') || true
  # shellcheck disable=SC2086
  set -- $out
  S_FILES=${1:-0}; S_DIRS=${2:-0}; S_BYTES=${3:-0}; S_LINKS=${4:-0}; S_OTHER=${5:-0}
  [ "${6:-0}" != 124 ] || S_PARTIAL=yes
}

lock_holder() {
  local u
  for u in "hs-bulk-sync:a parity sync" "hs-bulk-scrub:a scrub" "hs-cache-mover:the cache mover"; do
    if systemctl is-active -q "${u%%:*}.service" 2>/dev/null; then echo "${u#*:}"; return; fi
  done
  local f pid
  for f in "$fm_dir"/busy/*; do
    [ -f "$f" ] || continue
    pid=$(awk -F'\t' '$1 == "pid" { print $2; exit }' "$f" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "another file manager job"; return; }
  done
  echo "a pool change or another job"
}

claim_file() { printf '%s/claims/%s\n' "$fm_dir" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_')"; }
claim_alive() { local f pid; f=$(claim_file "$1"); [ -f "$f" ] || return 1; pid=$(cat "$f" 2>/dev/null || true); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

do_plan() {
  gate
  fm_resolve "$from" || refuse "$LERR"
  [ "$LUSABLE" = yes ] || refuse "$LERR"
  grab S_
  local ps; ps=$(fm_clean_path "$path") || refuse "the path must not contain .. , empty parts or control characters"
  local sdir=$S_ROOT${ps:+/$ps}
  [ -d "$sdir" ] || refuse "there is no folder '${ps:-/}' in ${S_LABEL}"
  srcdir=$(readlink -f -- "$sdir")
  case "$srcdir/" in "$S_ROOT"/*) ;; *) refuse "that path leaves the location" ;; esac
  srel=${srcdir#"$S_ROOT"}; srel=${srel#/}
  if [ -n "$srel" ]; then
    LTOP=$S_TOP; LKIND=$S_KIND
    fm_protected "" "${srel%%/*}"
    [ "$PROT" != system ] || refuse "${srel%%/*} belongs to the array and cannot be used"
  fi
  has_dst=no
  case "$op" in copy|move) has_dst=yes ;; esac

  if [ "$op" = mkdir ]; then
    SEL=()
    valid_newname "$newname" || refuse "--newname is one name without slash or control characters"
  else
    read_selection
    [ "${#SEL[@]}" -gt 0 ] || refuse "nothing is selected"
    if [ "$op" = rename ]; then
      [ "${#SEL[@]}" -eq 1 ] || refuse "rename takes exactly one item"
      valid_newname "$newname" || refuse "--newname is one name without slash or control characters"
    fi
  fi
  [ "$has_dst" = yes ] || [ -z "$to" ] || [ "$to" = "$from" ] || refuse "$op works inside one location"

  # permissions of the source side
  case "$op" in
    move|delete|rename) [ "$S_MOD" = yes ] || refuse "${S_LABEL}: ${S_REASON}; it is a source only, nothing can be removed or renamed there." ;;
    mkdir) [ "$S_ADD" = yes ] || refuse "${S_LABEL}: ${S_REASON}; no new folder can be made there." ;;
  esac
  if [ "$op" = mkdir ] || [ "$op" = rename ]; then
    if [ -z "$srel" ] && [ "$S_TOP" = yes ] && [ "$op" = mkdir ]; then refuse "The top of an array holds only shares and sensitive; new shares are made with hs share add."; fi
    local nn=$newname
    if [ -e "$srcdir/$nn" ] || [ -L "$srcdir/$nn" ]; then refuse "'$nn' exists already here"; fi
    LTOP=$S_TOP; LKIND=$S_KIND; fm_protected "$srel" "$nn"
    [ -z "$PROT" ] || refuse "'$nn' is a name the array keeps for itself"
  fi

  # the items
  local nm full
  for nm in "${SEL[@]}"; do
    full=$srcdir/$nm
    [ -e "$full" ] || [ -L "$full" ] || refuse "'$nm' does not exist in ${ps:-/}"
    LTOP=$S_TOP; LKIND=$S_KIND; LLABEL=$S_LABEL; LREL=$S_REL; LSNAP=$S_SNAP
    fm_protected "$srel" "$nm"
    case "$PROT" in
      array) refuse "'$nm' belongs to the array: it can be opened, but not selected, moved, renamed or deleted." ;;
      system) refuse "'$nm' belongs to the array (system file): it cannot be selected." ;;
    esac
    if [ -L "$full" ] && [ "$has_dst" = yes ]; then refuse "'$nm' is a link: links are not copied or moved here."; fi
    if fm_is_share_root "${srel:+$srel/}$nm"; then
      case "$op" in
        delete|rename) refuse "'$nm' is a share, not a folder: use hs share ... to rename or remove it." ;;
      esac
    fi
  done

  # the target
  dtdir=""; drel=""; rename_ok=no
  if [ "$has_dst" = yes ]; then
    [ -n "$to" ] || refuse "--to <location> is needed"
    fm_resolve "$to" || refuse "$LERR"
    [ "$LUSABLE" = yes ] || refuse "$LERR"
    grab D_
    local why
    if why=$(fm_same_files "$from" "$to"); then refuse "$why"; fi
    [ "$D_ADD" = yes ] || refuse "${D_LABEL} takes no files: ${D_REASON}."
    local pd; pd=$(fm_clean_path "$topath") || refuse "the target path must not contain .. , empty parts or control characters"
    local tdir=$D_ROOT${pd:+/$pd}
    [ -d "$tdir" ] || refuse "there is no target folder '${pd:-/}' in ${D_LABEL}; make it first."
    dtdir=$(readlink -f -- "$tdir")
    case "$dtdir/" in "$D_ROOT"/*) ;; *) refuse "the target path leaves the location" ;; esac
    drel=${dtdir#"$D_ROOT"}; drel=${drel#/}
    if [ -z "$drel" ] && [ "$D_TOP" = yes ]; then refuse "The top of an array holds only shares and sensitive; choose a folder below one of them."; fi
    if [ -n "$drel" ]; then
      LTOP=$D_TOP; LKIND=$D_KIND; fm_protected "" "${drel%%/*}"
      [ "$PROT" != system ] || refuse "${drel%%/*} belongs to the array and cannot be used"
    fi
    for nm in "${SEL[@]}"; do
      if [ -d "$srcdir/$nm" ] && [ ! -L "$srcdir/$nm" ]; then
        case "$dtdir/" in "$srcdir/$nm"/*) refuse "'$nm' cannot be put into itself." ;; esac
      fi
      LTOP=$S_TOP; LKIND=$S_KIND; LREL=$S_REL
      if fm_is_share_root "${srel:+$srel/}$nm"; then
        [ "$S_KIND" = disk ] && [ "$D_KIND" = disk ] || refuse "'$nm' is a share folder: it can only go from one data disk to another."
      fi
    done
    if [ "$op" = move ] && [ "$srcdir" = "$dtdir" ]; then refuse "The files are in that folder already."; fi
    if [ "$op" = move ] && [ "${HS_FM_NO_RENAME:-0}" != 1 ] && [ "$(stat -c %d -- "$srcdir")" = "$(stat -c %d -- "$dtdir")" ]; then rename_ok=yes; fi
    if [ "$op" = move ]; then
      case "$policy" in newer|overwrite) refuse "Overwrite is refused together with move: copy first, then delete, or choose skip / rename." ;; esac
    fi
  fi

  # sizes
  local -a paths=()
  for nm in "${SEL[@]}"; do paths+=("$srcdir/$nm"); done
  scan_timeout=${FM_SCAN_TIMEOUT:-60}
  if [ "$op" = mkdir ] || [ "$op" = rename ]; then S_FILES=0; S_DIRS=0; S_BYTES=0; S_LINKS=0; S_OTHER=0; S_PARTIAL=no
  else fm_scan "$scan_timeout" "${paths[@]}"; fi
  files=$S_FILES; folders=$S_DIRS; bytes=$S_BYTES; links=$S_LINKS; others=$S_OTHER; partial=$S_PARTIAL

  # room
  free_after=""
  if [ "$has_dst" = yes ]; then
    local avail margin need
    avail=$(df -B1 --output=avail -- "$dtdir" 2>/dev/null | tail -n1 | tr -d ' ' || true); avail=${avail:-0}
    if [ "$rename_ok" = yes ]; then free_after=$avail
    else
      margin=${HS_FM_MARGIN:-$([ "$D_KIND" = disk ] && echo $((10 * 1024 * 1024 * 1024)) || echo $((1024 * 1024 * 1024)))}
      need=$((bytes + margin))
      if [ "$bytes" -gt 0 ] && [ "$avail" -lt "$need" ]; then
        refuse "${D_LABEL} has $(fm_human "$avail") free; this needs $(fm_human "$bytes") plus a margin of $(fm_human "$margin")."
      fi
      free_after=$((avail - bytes)); [ "$free_after" -ge 0 ] || free_after=0
    fi
  fi

  # conflicts
  conflicts=0; conflict_rows=()
  if [ "$has_dst" = yes ]; then
    local y s t p rel d
    for nm in "${SEL[@]}"; do
      [ -e "$dtdir/$nm" ] || [ -L "$dtdir/$nm" ] || continue
      while IFS=$'\001' read -r -d '' y s t p; do
        rel=${p#"$srcdir"/}; d=$dtdir/$rel
        [ "$y" != d ] || { if [ -e "$d" ] || [ -L "$d" ]; then [ -d "$d" ] && [ ! -L "$d" ] && continue; else continue; fi; }
        [ "$y" = f ] || [ "$y" = d ] || continue
        if [ -e "$d" ] || [ -L "$d" ]; then
          conflicts=$((conflicts + 1))
          if [ "$want_conflicts" = yes ] && [ "${#conflict_rows[@]}" -lt 2000 ]; then
            conflict_rows+=("$(printf 'conflict\t%s\t%s\t%s\t%s\t%s' "$(fm_badname "$rel" && fm_esc "$rel" || printf '%s' "$rel")" "$s" "$(stat -c %s -- "$d" 2>/dev/null || echo 0)" "${t%.*}" "$(stat -c %Y -- "$d" 2>/dev/null || echo 0)")")
          fi
        fi
      done < <(timeout "$scan_timeout" find -P "$srcdir/$nm" -xdev -printf '%y\001%s\001%T@\001%p\0' 2>/dev/null)
    done
  fi

  # confirmation
  confirm_name=""
  if [ "$op" = delete ]; then
    if [ "$files" -eq 1 ]; then confirm_name="delete 1 file"; else confirm_name="delete $files files"; fi
  elif [ "$has_dst" = yes ] && { [ "$policy" = newer ] || [ "$policy" = overwrite ]; }; then
    local tn=${dtdir##*/}; [ -n "$tn" ] || tn=$D_LABEL
    [ -n "$drel" ] || tn=${D_ID#*:}
    confirm_name=$(sanitize_confirm "$tn")
  fi

  parity=no
  if [ "$S_SNAP" = yes ] && { [ "$op" = move ] || [ "$op" = delete ]; } && [ "$S_KIND" != cache ]; then parity=yes; fi
  lock_any=no
  [ "$S_LOCK" != yes ] || lock_any=yes
  [ "$has_dst" != yes ] || [ "$D_LOCK" != yes ] || lock_any=yes

  # who else is working
  if claim_alive "$S_ID"; then refuse "Another file job is working on ${S_LABEL} already; wait until it is done."; fi
  if [ "$now" != yes ] && [ "$lock_any" = yes ]; then
    if ! ( exec 9>"$bulk_lock"; flock -n 9 ) 2>/dev/null; then
      refuse "$(lock_holder) is running and holds the bulk lock; try again when it is done."
    fi
  fi

  long=no
  if [ "$rename_ok" != yes ] && { [ "$bytes" -gt $((20 * 1024 * 1024 * 1024)) ] || [ "$files" -gt 20000 ]; }; then long=yes; fi
  if [ "$partial" = yes ]; then long=yes; fi
}

plan_lines() {
  local what hb hs_
  hb=$(fm_human "$bytes")
  local src_txt="${S_LABEL}:/${srel}"
  local dst_txt=""; if [ "$has_dst" = yes ]; then dst_txt="${D_LABEL}:/${drel}"; fi
  echo "status	ok"
  local n=${#SEL[@]}
  case "$op" in
    copy)   printf 'heading\tcopy %s item(s) (%s) from %s to %s\n' "$n" "$hb" "$src_txt" "$dst_txt" ;;
    move)   printf 'heading\tmove %s item(s) (%s) from %s to %s\n' "$n" "$hb" "$src_txt" "$dst_txt" ;;
    delete) printf 'heading\tdelete %s item(s) (%s) from %s\n' "$n" "$hb" "$src_txt" ;;
    rename) printf 'heading\trename %s to %s in %s\n' "${SEL[0]}" "$newname" "$src_txt" ;;
    mkdir)  printf 'heading\tnew folder %s in %s\n' "$newname" "$src_txt" ;;
  esac
  case "$op" in
    copy)
      printf 'step\t+ copy %s files in %s folders (%s) to %s, each to a temporary name first, renamed when complete\n' "$files" "$folders" "$hb" "$dst_txt"
      printf 'step\t~ check every copied file (%s) before it counts as done\n' "$([ "$verify" = checksum ] && echo 'size, modification time and content' || echo 'size and modification time')" ;;
    move)
      if [ "$rename_ok" = yes ]; then
        printf 'step\t~ move %s files in %s folders to %s: same filesystem, so a rename (instant)\n' "$files" "$folders" "$dst_txt"
      else
        printf 'step\t+ copy %s files in %s folders (%s) to %s, each to a temporary name first\n' "$files" "$folders" "$hb" "$dst_txt"
        printf 'step\t~ check every copied file (%s)\n' "$([ "$verify" = checksum ] && echo 'size, modification time and content' || echo 'size and modification time')"
        printf 'step\t- remove each file from %s only after it is checked; anything unchecked stays\n' "$src_txt"
      fi ;;
    delete) printf 'step\t- delete %s files and %s folders (%s) from %s\n' "$files" "$folders" "$hb" "$src_txt" ;;
    rename) printf 'step\t~ rename %s to %s\n' "${SEL[0]}" "$newname" ;;
    mkdir)  printf 'step\t+ make the folder %s\n' "$newname" ;;
  esac
  if [ "$has_dst" = yes ]; then
    case "$policy" in
      skip) [ "$conflicts" -eq 0 ] || printf 'step\t~ %s file(s) exist at the target already: they are left alone (skipped)\n' "$conflicts" ;;
      rename) [ "$conflicts" -eq 0 ] || printf 'step\t~ %s file(s) exist at the target already: the new ones get a name like "name (1).ext"\n' "$conflicts" ;;
      newer) printf 'step\t~ %s file(s) exist at the target: replaced when the source is newer, otherwise skipped\n' "$conflicts" ;;
      overwrite) printf 'step\t~ %s file(s) exist at the target: they are REPLACED\n' "$conflicts" ;;
    esac
  fi
  write_on || printf 'warn\tThe file manager is read only (fileManagerWrite is off): this plan shows what would happen, Start is refused until you allow it in Settings.\n'
  [ "$op" != delete ] || echo "warn	Delete is permanent: there is no trash. The backup and ZFS snapshots are the only way back."
  if [ "$has_dst" = yes ] && { [ "$policy" = newer ] || [ "$policy" = overwrite ]; }; then echo "warn	Overwriting replaces files at the target for good. Type the target name to confirm."; fi
  [ "$links" -eq 0 ] && [ "$others" -eq 0 ] || { [ "$op" = delete ] && printf 'note\t%s link(s) and %s special file(s) are removed as they are, never followed.\n' "$links" "$others" || printf 'warn\t%s link(s) and %s special file(s) in the selection are skipped: links are never followed or copied.\n' "$links" "$others"; }
  [ "$partial" != yes ] || echo "note	The folders are very big: the counts are a first part only; the job checks the room as it goes."
  if [ "$parity" = yes ]; then
    echo "note	The SnapRAID parity is out of date afterwards: files taken off a data disk count as removed until the next sync (hs pool bulk sync)."
    [ "$parity_after" != yes ] || echo "note	The parity is updated when this is done (a second job)."
  fi
  if [ "$has_dst" = yes ] && [ "$D_KIND" = pool ] && [ "$D_SNAP" = yes ]; then echo "note	The pool chooses the disk for each new file by its own rule; a disk with little room can refuse a file."; fi
  if [ "$S_LOCK" = yes ] || [ "${D_LOCK:-no}" = yes ]; then echo "note	The parity sync and the cache mover wait until this is done."; fi
  printf 'files\t%s\nfolders\t%s\nbytes\t%s\n' "$files" "$folders" "$bytes"
  [ -z "$free_after" ] || printf 'free_after\t%s\n' "$free_after"
  printf 'conflicts\t%s\nparity\t%s\nconfirm_name\t%s\nlong\t%s\n' "$conflicts" "$parity" "$confirm_name" "$long"
  if [ "$want_conflicts" = yes ] && [ "${#conflict_rows[@]}" -gt 0 ]; then printf '%s\n' "${conflict_rows[@]}"; fi
}

# ======================================================================= the job
audit_done=no
audit() {   # audit <result>
  [ "$audit_done" = no ] || return 0
  audit_done=yes
  mkdir -p "$fm_dir" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\titems=%s\tfiles=%s\tbytes=%s\tskipped=%s\tfailed=%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$by" "$op" "${S_ID:-$from}:/${srel:-}" "${D_ID:+$D_ID:/$drel}" \
    "${#SEL[@]}" "${files_done:-0}" "${bytes_done:-0}" "${skipped:-0}" "${failed:-0}" "$1" >> "$fm_dir/audit.log" 2>/dev/null || true
}

j_skip() { skipped=$((skipped + 1)); [ "$skipped" -gt 5000 ] || printf '%s\t%s\n' "$1" "$2" >> "$skf"; }
j_fail() { failed=$((failed + 1)); [ "$failed" -gt 5000 ] || printf '%s\t%s\n' "$1" "$2" >> "$failf"; }

st_write() {
  local el sp=0 eta=0 cur=$current i pct
  el=$((SECONDS - t0)); [ "$el" -le 0 ] || sp=$((bytes_done / el))
  if [ "$sp" -gt 0 ] && [ "$bytes_total" -gt "$bytes_done" ]; then eta=$(((bytes_total - bytes_done) / sp)); fi
  if fm_badname "$cur"; then cur=$(fm_esc "$cur"); fi
  {
    printf 'files_done\t%s\nfiles_total\t%s\nbytes_done\t%s\nbytes_total\t%s\nspeed\t%s\neta\t%s\ncurrent\t%s\nphase\t%s\nresult\t%s\nskipped\t%s\nfailed\t%s\n' \
      "$files_done" "$files_total" "$bytes_done" "$bytes_total" "$sp" "$eta" "$cur" "$phase" "$result" "$skipped" "$failed"
    printf 'op\t%s\nfrom\t%s\nto\t%s\npid\t%s\njob\t%s\n' "$op" "${S_ID}:/${srel}" "${D_ID:+$D_ID:/$drel}" "$$" "$jobid"
  } > "$sf.tmp" 2>/dev/null && mv -f "$sf.tmp" "$sf" 2>/dev/null || true
  if [ -n "${busyf:-}" ]; then
    {
      printf 'pid\t%s\n' "$$"
      for ((i = 0; i < ${#SEL[@]}; i++)); do
        if [ "${idone_flag[i]:-0}" = 1 ]; then pct=100
        elif [ "${ibytes[i]:-0}" -gt 0 ]; then pct=$((idone[i] * 100 / ibytes[i])); [ "$pct" -le 99 ] || pct=99
        else pct=0; fi
        printf 'item\t%s\t%s\t%s\t%s\n' "$S_AK" "${bsrc[i]}" "$op" "$pct"
        [ -z "${bdst[i]:-}" ] || printf 'item\t%s\t%s\t%s\t%s\n' "$D_AK" "${bdst[i]}" "$op" "$pct"
      done
    } > "$busyf.tmp" 2>/dev/null && mv -f "$busyf.tmp" "$busyf" 2>/dev/null || true
  fi
}
st_tick() { if [ "$SECONDS" -ne "$last_tick" ]; then last_tick=$SECONDS; st_write; fi; }

on_term() { cancelled=1; }
on_exit() {
  local rc=$?
  [ -z "${cur_tmp:-}" ] || rm -f -- "$cur_tmp" 2>/dev/null || true
  if [ "$result" = running ]; then
    if [ "$cancelled" = 1 ]; then result=cancelled; else result=failed; phase="the job ended unexpectedly (exit $rc)"; fi
  fi
  [ -z "${sf:-}" ] || st_write
  [ -z "${busyf:-}" ] || rm -f -- "$busyf" "$busyf.tmp" 2>/dev/null || true
  [ -z "${claimf:-}" ] || rm -f -- "$claimf" 2>/dev/null || true
  [ "$took_admin" != yes ] || rm -f -- "$bulk_admin" 2>/dev/null || true
  audit "${result:-failed}"
}

chown_mode=ref; admin_ids=""
setup_chown() {
  local darel
  if [ "$has_dst" = yes ]; then fm_arel_for "$D_REL" "$drel"; darel=$AREL; else darel=""; fi
  case "$darel" in
    sensitive|sensitive/*) chown_mode=ref ;;
    shares|shares/*) chown_mode=admin ;;
    *) case "${D_KIND:-}" in share|cache|pool) chown_mode=admin ;; *) chown_mode=ref ;; esac ;;
  esac
  if [ "${S_KIND:-}" = temp ]; then chown_mode=admin; fi
  if [ "$(id -u)" = 0 ] && [ "$fm_test" != 1 ]; then
    admin_ids="$(id -u adminuser 2>/dev/null || echo 0):$(id -g adminuser 2>/dev/null || echo 0)"
  fi
}
fm_arel_for() { if [ -n "$1" ] && [ -n "$2" ]; then AREL=$1/$2; elif [ -n "$1" ]; then AREL=$1; else AREL=$2; fi; }
fm_chown() {   # fm_chown <new> <like>
  [ "$(id -u)" = 0 ] && [ "$fm_test" != 1 ] || return 0
  if [ "$chown_mode" = ref ]; then chown -h --reference="$2" -- "$1" 2>/dev/null || true
  else chown -h "$admin_ids" -- "$1" 2>/dev/null || true; fi
}

# copy (or move) one regular file
do_file() {   # do_file <src> <dst> <rel> <size> <mtime>
  local src=$1 dst=$2 rel=$3 size=$4 mt=$5 ex=no dd tmp s1 s2 s3 dmt
  dd=${dst%/*}
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ -d "$dst" ] && [ ! -L "$dst" ]; then j_fail "$rel" "a folder with that name is in the way"; return 0; fi
    if [ "$src" -ef "$dst" ]; then j_fail "$rel" "source and target are the same file; left alone"; return 0; fi
    case "$policy" in
      skip) j_skip "$rel" "exists at the target"; return 0 ;;
      rename) dst=$(fm_free_name "$dst") ;;
      newer)
        dmt=$(stat -c %Y -- "$dst" 2>/dev/null || echo 0)
        if [ "$mt" -gt "$dmt" ]; then ex=yes; else j_skip "$rel" "the target is not older"; return 0; fi ;;
      overwrite) ex=yes ;;
    esac
  fi
  if [ "$op" = move ] && [ "$rename_ok" = yes ]; then
    if mv -T -- "$src" "$dst" 2>/dev/null; then return 0; fi
    j_fail "$rel" "rename failed"; return 1
  fi
  tmp=$dd/.hs-fm-partial.$$.$RANDOM
  cur_tmp=$tmp
  s1=$(stat -c '%s %Y' -- "$src" 2>/dev/null || echo gone)
  if ! cp -P --preserve=mode,timestamps -- "$src" "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"; cur_tmp=""; j_fail "$rel" "the copy failed (no room, or no access)"; return 1
  fi
  s2=$(stat -c '%s %Y' -- "$src" 2>/dev/null || echo gone)
  s3=$(stat -c '%s %Y' -- "$tmp" 2>/dev/null || echo none)
  if [ "$s1" != "$s2" ]; then rm -f -- "$tmp"; cur_tmp=""; j_fail "$rel" "the file changed while it was copied; left where it is"; return 1; fi
  if [ "$s1" != "$s3" ]; then rm -f -- "$tmp"; cur_tmp=""; j_fail "$rel" "the copy does not match (size or time)"; return 1; fi
  if [ "$verify" = checksum ] && ! cmp -s -- "$src" "$tmp"; then rm -f -- "$tmp"; cur_tmp=""; j_fail "$rel" "the content of the copy differs"; return 1; fi
  fm_chown "$tmp" "$src"
  if [ "$ex" != yes ] && { [ -e "$dst" ] || [ -L "$dst" ]; }; then rm -f -- "$tmp"; cur_tmp=""; j_skip "$rel" "appeared at the target meanwhile"; return 0; fi
  if ! mv -T -- "$tmp" "$dst" 2>/dev/null; then rm -f -- "$tmp"; cur_tmp=""; j_fail "$rel" "could not put the copy in place"; return 1; fi
  cur_tmp=""
  if [ "$op" = move ]; then
    # the source goes only now, and only when the target is there and as big as it must be
    if [ "$(stat -c %s -- "$dst" 2>/dev/null || echo -1)" = "${s1%% *}" ]; then
      rm -f -- "$src" 2>/dev/null || j_fail "$rel" "copied, but the source could not be removed"
    else
      j_fail "$rel" "the copy could not be checked; the source stays"
    fi
  fi
  return 0
}

job_copy_move() {
  local i name src dst y s t p rel d skipdir made_src made_dst srcdirs k
  for ((i = 0; i < ${#SEL[@]}; i++)); do
    [ "$cancelled" = 0 ] || break
    name=${SEL[i]}; src=$srcdir/$name; dst=$dtdir/$name
    current=$name; cur_i=$i
    if [ "$op" = move ] && [ "$rename_ok" = yes ] && [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      if mv -T -- "$src" "$dst" 2>/dev/null; then
        files_done=$((files_done + ifiles[i])); bytes_done=$((bytes_done + ibytes[i])); idone[i]=${ibytes[i]}; idone_flag[i]=1
        st_tick; continue
      fi
    fi
    skipdir=""; made_src=(); made_dst=(); srcdirs=()
    while IFS=$'\001' read -r -d '' y s t p; do
      [ "$cancelled" = 0 ] || break
      rel=${p#"$srcdir"/}; d=$dtdir/$rel; current=$rel
      if [ -n "$skipdir" ] && [[ $rel == "$skipdir"/* ]]; then
        [ "$y" != f ] || { j_skip "$rel" "its folder could not be made"; files_done=$((files_done + 1)); }
        continue
      fi
      case $y in
        d)
          srcdirs+=("$p")
          if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then j_fail "$rel" "a file with that name is in the way"; skipdir=$rel; continue; fi
          if [ ! -d "$d" ]; then
            if mkdir -- "$d" 2>/dev/null; then fm_chown "$d" "$p"; made_src+=("$p"); made_dst+=("$d")
            else j_fail "$rel" "the folder could not be made"; skipdir=$rel; continue; fi
          fi ;;
        f)
          do_file "$p" "$d" "$rel" "$s" "${t%.*}" || true
          files_done=$((files_done + 1)); bytes_done=$((bytes_done + s)); idone[i]=$((idone[i] + s)) ;;
        *) j_skip "$rel" "a link or special file is not copied"; files_done=$((files_done + 1)) ;;
      esac
      st_tick
    done < <(find -P "$src" -xdev -printf '%y\001%s\001%T@\001%p\0' 2>/dev/null)
    # folders: times and modes after their content; a moved folder goes when it is empty
    for ((k = ${#made_dst[@]} - 1; k >= 0; k--)); do
      touch -r "${made_src[k]}" -- "${made_dst[k]}" 2>/dev/null || true
      chmod --reference="${made_src[k]}" -- "${made_dst[k]}" 2>/dev/null || true
    done
    if [ "$op" = move ]; then
      for ((k = ${#srcdirs[@]} - 1; k >= 0; k--)); do rmdir -- "${srcdirs[k]}" 2>/dev/null || true; done
    fi
    idone_flag[i]=1
    st_write
  done
}

job_delete() {
  local i name src y s t p rel
  for ((i = 0; i < ${#SEL[@]}; i++)); do
    [ "$cancelled" = 0 ] || break
    name=${SEL[i]}; src=$srcdir/$name; current=$name
    while IFS=$'\001' read -r -d '' y s t p; do
      [ "$cancelled" = 0 ] || break
      rel=${p#"$srcdir"/}; current=$rel
      case $y in
        d) rmdir -- "$p" 2>/dev/null || j_fail "$rel" "the folder is not empty or busy" ;;
        *) if rm -f -- "$p" 2>/dev/null; then files_done=$((files_done + 1)); bytes_done=$((bytes_done + s)); idone[i]=$((idone[i] + s))
           else j_fail "$rel" "could not be deleted"; fi ;;
      esac
      st_tick
    done < <(find -P "$src" -xdev -depth -printf '%y\001%s\001%T@\001%p\0' 2>/dev/null)
    idone_flag[i]=1
    st_write
  done
}

run_job() {
  set +e
  [ -n "$jobid" ] || jobid=$(date +%s)-$$
  mkdir -p "$fm_dir/jobs" "$fm_dir/busy" "$fm_dir/claims"; chmod 700 "$fm_dir" 2>/dev/null || true
  sf=$fm_dir/jobs/$jobid.state; skf=$fm_dir/jobs/$jobid.skipped; failf=$fm_dir/jobs/$jobid.failed; busyf=$fm_dir/busy/$jobid
  : > "$skf"; : > "$failf"
  files_done=0; files_total=0; bytes_done=0; bytes_total=0; skipped=0; failed=0; current=""; phase=starting; result=running
  cancelled=0; took_admin=no; cur_tmp=""; claimf=""; last_tick=-1; t0=$SECONDS
  ifiles=(); ibytes=(); idone=(); idone_flag=(); bsrc=(); bdst=()   # global: the exit trap writes the state last
  trap on_term TERM INT
  trap on_exit EXIT
  local i a
  for ((i = 0; i < ${#SEL[@]}; i++)); do
    idone[i]=0; idone_flag[i]=0
    if [ "$op" = mkdir ] || [ "$op" = rename ]; then ifiles[i]=0; ibytes[i]=0
    else fm_scan 600 "$srcdir/${SEL[i]}"; ifiles[i]=$S_FILES; ibytes[i]=$S_BYTES; fi
    files_total=$((files_total + ifiles[i])); bytes_total=$((bytes_total + ibytes[i]))
    fm_arel_for "$S_REL" "${srel:+$srel/}${SEL[i]}"; bsrc[i]=$AREL
    if [ "$has_dst" = yes ]; then fm_arel_for "$D_REL" "${drel:+$drel/}${SEL[i]}"; bdst[i]=$AREL; fi
  done
  [ "$op" != mkdir ] || { fm_arel_for "$S_REL" "${srel:+$srel/}$newname"; bsrc[0]=$AREL; SEL=("$newname"); ifiles[0]=0; ibytes[0]=0; idone[0]=0; idone_flag[0]=0; }
  st_write
  # one job per source
  mkdir -p "$fm_dir/claims"
  claimf=$(claim_file "$S_ID")
  if claim_alive "$S_ID"; then phase="another file job works on ${S_LABEL}"; result=failed; claimf=""; st_write; return 1; fi
  echo $$ > "$claimf" 2>/dev/null || true
  # the bulk lock
  if [ "$lock_any" = yes ]; then
    phase="waiting for the bulk lock"; st_write
    exec 9>"$bulk_lock"
    if ! flock -w "${HS_FM_LOCK_WAIT:-21600}" 9; then phase="the bulk lock stayed taken ($(lock_holder))"; result=failed; st_write; return 1; fi
    : > "$bulk_admin"; took_admin=yes
  fi
  setup_chown
  phase=running; st_write
  case "$op" in
    copy|move) job_copy_move ;;
    delete) job_delete ;;
    rename)
      current=${SEL[0]}
      if [ -e "$srcdir/$newname" ] || [ -L "$srcdir/$newname" ]; then j_fail "$newname" "exists already"
      elif mv -T -- "$srcdir/${SEL[0]}" "$srcdir/$newname" 2>/dev/null; then files_done=1; else j_fail "${SEL[0]}" "rename failed"; fi
      idone_flag[0]=1 ;;
    mkdir)
      current=$newname
      if mkdir -- "$srcdir/$newname" 2>/dev/null; then fm_chown "$srcdir/$newname" "$srcdir"; files_done=1; else j_fail "$newname" "the folder could not be made"; fi
      idone_flag[0]=1 ;;
  esac
  current=""
  if [ "$cancelled" = 1 ]; then result=cancelled; phase="cancelled: what was copied stays, nothing unchecked was removed"
  elif [ "$failed" -gt 0 ]; then result=failed; phase="finished with $failed failed item(s)"
  else result=done; phase=finished; fi
  st_write
  if [ "$result" = done ] && [ "$parity_after" = yes ] && [ "$parity" = yes ]; then
    if [ "$took_admin" = yes ]; then exec 9>&-; rm -f -- "$bulk_admin"; took_admin=no; fi
    if [ -n "${HS_FM_PARITY_CMD:-}" ]; then bash -c "$HS_FM_PARITY_CMD" >/dev/null 2>&1
    else . "$here/lib/job.sh"; hs_job "pool-bulk-sync" "update the parity after the file manager" -- bash "$here/bulk-sync.sh" >/dev/null 2>&1; fi
  fi
  [ "$result" = done ] && return 0
  [ "$result" = cancelled ] && return 0
  return 1
}

cmd_plan() {
  parse_args "$@"
  do_plan
  plan_lines
}

cmd_start() {
  parse_args "$@"
  write_on || refuse "$WRITE_OFF_REASON"
  do_plan
  if [ -n "$confirm_name" ] && [ "$confirm" != "$confirm_name" ]; then refuse "type the confirmation to go on: $confirm_name"; fi
  if [ "$now" = yes ]; then
    run_job
    local rc=$?
    printf 'status\tdone\nresult\t%s\n' "$result"
    return $rc
  fi
  mkdir -p "$fm_dir/jobs" "$fm_dir/busy" "$fm_dir/claims" 2>/dev/null || refuse "$fm_dir is not writable"
  chmod 700 "$fm_dir" 2>/dev/null || true
  local id sel desc unit
  id=$(date +%s)-$$-$RANDOM
  sel=$fm_dir/jobs/$id.sel
  if [ "$op" != mkdir ]; then printf '%s\0' "${SEL[@]}" > "$sel"; else : > "$sel"; fi
  desc="$op ${#SEL[@]} item(s) in ${S_LABEL}"; [ "$op" != mkdir ] || desc="new folder in ${S_LABEL}"
  local -a args=("$op" --from "$from" --path "$path" --conflict "$policy" --verify "$verify" --by "$by" --job-id "$id" --sel-file "$sel" --now)
  [ -z "$to" ] || args+=(--to "$to" --to-path "$topath")
  [ -z "$newname" ] || args+=(--newname "$newname")
  [ -z "$confirm" ] || args+=(--confirm "$confirm")
  [ "$parity_after" != yes ] || args+=(--parity-after)
  if [ "${HS_FM_SYNC:-0}" = 1 ]; then
    unit=hs-job-fm-test-$id
    printf '%s\n' "$id" > "$fm_dir/jobs/$unit.alias"
    bash "$here/fm.sh" start "${args[@]}" >/dev/null || true
  elif [ "$fm_test" = 1 ]; then
    unit=hs-job-fm-test-$id
    printf '%s\n' "$id" > "$fm_dir/jobs/$unit.alias"
    nohup bash "$here/fm.sh" start "${args[@]}" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$fm_dir/jobs/$unit.pid"
  else
    . "$here/lib/job.sh"
    unit=$(hs_job "fm-$op" "$desc" -- bash "$here/fm.sh" start "${args[@]}") || refuse "the job could not be started"
    printf '%s\n' "$id" > "$fm_dir/jobs/$unit.alias"
  fi
  printf 'status\tdone\nunit\t%s\nid\t%s\n' "$unit" "$id"
}

cmd_progress() {
  gate
  [ $# -eq 1 ] || refuse "usage: progress <unit>"
  local unit=$1 id sf pid
  [[ $unit =~ ^[A-Za-z0-9@._-]{1,100}$ ]] || refuse "that is not a job"
  unit=${unit%.service}
  if [ -f "$fm_dir/jobs/$unit.alias" ]; then id=$(cat "$fm_dir/jobs/$unit.alias"); else id=$unit; fi
  [[ $id =~ ^[A-Za-z0-9._-]{1,60}$ ]] || refuse "that is not a job"
  sf=$fm_dir/jobs/$id.state
  if [ ! -f "$sf" ]; then
    if systemctl is-active -q "$unit.service" 2>/dev/null || [ -f "$fm_dir/jobs/$unit.alias" ]; then
      printf 'status\tok\nfiles_done\t0\nfiles_total\t0\nbytes_done\t0\nbytes_total\t0\nspeed\t0\neta\t0\ncurrent\t\nphase\tstarting\nresult\trunning\nskipped\t0\nfailed\t0\n'
      return 0
    fi
    refuse "there is no file manager job '$unit'"
  fi
  echo "status	ok"
  pid=$(awk -F'\t' '$1 == "pid" { print $2; exit }' "$sf")
  local res; res=$(awk -F'\t' '$1 == "result" { print $2; exit }' "$sf")
  if [ "$res" = running ] && [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    awk -F'\t' '$1 == "result" { print "result\tfailed"; next } $1 == "phase" { print "phase\tthe job ended without a result"; next } $1 != "pid" { print }' "$sf"
  else
    grep -v '^pid	' "$sf" || true
  fi
  local k f
  for k in skipped failed; do
    f=$fm_dir/jobs/$id.$k
    [ -s "$f" ] || continue
    awk -F'\t' -v t="$([ "$k" = skipped ] && echo skip || echo fail)" 'NR <= 200 { printf "%s\t%s\t%s\n", t, $1, $2 }' "$f"
  done
}

case "$verb" in
  locations) cmd_locations "$@" ;;
  pair)      cmd_pair "$@" ;;
  ls)        cmd_ls "$@" ;;
  plan)      cmd_plan "$@" ;;
  start)     cmd_start "$@" ;;
  progress)  cmd_progress "$@" ;;
esac
