# shellcheck shell=bash
# The file manager's locations and path rules (docs/PLAN-file-manager.md). Sourced by scripts/fm.sh, not run.
#
#   fm_resolve <id>        fills L*: LID LKIND LLABEL LROOT (real path) LFS LSIZE LFREE LADD (may receive files) LMOD (files may be removed/renamed in it)
#                          LREASON (why not writable, or -) LPOOL LDISK LUSABLE (yes|no; LERR says why not) LAK (array key: what busy marks are keyed by)
#                          LREL (path of the root below the array root) LTOP (the root is the top of an array: shares/ and sensitive/ are protected)
#                          LSNAP (SnapRAID layout: a parity exists) LLOCK (touching it needs the bulk lock)
#                          returns 1 for an unknown id or locked storage (LERR says which)
#   fm_same_files <a> <b>  prints the reason and returns 0 when the two locations show the same files (a pool disk and the pool view of its array)
#   fm_clean_path <p>      the path relative to the root, no leading/trailing slash; returns 1 for .., control characters, empty parts
#   fm_badname <name>      true when a name has control characters or is not valid UTF-8
#   fm_esc <name>          the name with every unsafe byte as \xNN (prints it)
#
# Test knobs: HS_FM_TEST=1 (every folder counts as mounted), HS_FM_POOL_ROOT, HS_FM_ZFS_ROOT, HS_FM_CACHE_ROOT, HS_FM_FAST_ROOT, HS_FM_TEMP_ROOT,
# HS_BULK_TYPE_FILE, HS_STATE_DIR, HS_BULK_CLOSED, HS_DISKS_ROOT, HS_DETACHED_ROOT, HS_LOCKED_MARKER.
. "$(dirname "${BASH_SOURCE[0]}")/bulkpath.sh"
. "$(dirname "${BASH_SOURCE[0]}")/locked.sh"

fm_state_dir=${HS_STATE_DIR:-/var/lib/hs}
fm_dir=${HS_FM_DIR:-$fm_state_dir/fm}
fm_test=${HS_FM_TEST:-0}

fm_bulk_type() { local t; t=$(cat "${HS_BULK_TYPE_FILE:-/etc/hs/bulk-type}" 2>/dev/null || true); echo "${t:-zfs}"; }
fm_ismnt() { if [ "$fm_test" = 1 ]; then [ -d "$1" ]; else mountpoint -q "$1" 2>/dev/null; fi; }
fm_human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
fm_readonly() {
  if [ "$fm_test" = 1 ]; then [ -e "$1/.fm-readonly" ]; return; fi
  findmnt -no OPTIONS -T "$1" 2>/dev/null | tr ',' '\n' | grep -qx ro
}

fm_pool_root() { echo "${HS_FM_POOL_ROOT:-/mnt/bulk/pool}"; }
fm_zfs_root() { echo "${HS_FM_ZFS_ROOT:-/bulk}"; }
fm_cache_root() { echo "${HS_FM_CACHE_ROOT:-/mnt/bulk/cache}"; }
fm_fast_root() { echo "${HS_FM_FAST_ROOT:-/fast}"; }
fm_temp_root() { echo "${HS_FM_TEMP_ROOT:-/mnt/temp}"; }
fm_is_closed() { grep -qx "$1" "${HS_BULK_CLOSED:-$fm_state_dir/bulk-closed}" 2>/dev/null; }

fm_clean_path() {
  local p=$1
  while [ "${p:0:1}" = / ]; do p=${p:1}; done
  p=${p%/}
  while [ "${p: -1}" = / ]; do p=${p%/}; done
  if [ -n "$p" ]; then
    ( LC_ALL=C; [[ $p == *[[:cntrl:]]* ]] ) && return 1
    case "/$p/" in */../*|*//*|*/./*) return 1 ;; esac
  fi
  printf '%s\n' "$p"
}

fm_badname() {
  local LC_ALL=C n=$1
  [[ $n == *[!\ -~]* ]] || return 1
  [[ $n == *[[:cntrl:]]* ]] && return 0
  printf '%s' "$n" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && return 1
  return 0
}

fm_esc() {
  local LC_ALL=C n=$1 out="" c i hx
  for ((i = 0; i < ${#n}; i++)); do
    c=${n:i:1}
    printf -v hx '%d' "'$c"
    if [ "$hx" -lt 32 ] || [ "$hx" -gt 126 ] || [ "$c" = '\' ]; then printf -v c '\\x%02x' "$hx"; fi
    out+=$c
  done
  printf '%s\n' "$out"
}

fm_fill_size() {   # size/free/fs of LROOT
  local s a
  read -r s a < <(df -B1 --output=size,avail -- "$LROOT" 2>/dev/null | tail -n +2) || true
  LSIZE=${s:-0}; LFREE=${a:-0}
  LFS=$(findmnt -no FSTYPE -T "$LROOT" 2>/dev/null | head -n1) || true
  [ -n "$LFS" ] || LFS=$(stat -f -c %T -- "$LROOT" 2>/dev/null || echo "-")
}

fm_resolve() {
  local id=$1 n dir
  LID=$id; LKIND=""; LLABEL=""; LROOT=""; LFS="-"; LSIZE=0; LFREE=0; LADD=no; LMOD=no; LREASON="-"; LPOOL="-"; LDISK="-"
  LUSABLE=yes; LERR=""; LAK=$id; LREL=""; LTOP=no; LSNAP=no; LLOCK=no
  [[ $id =~ ^(disk:data-[0-9]{1,3}|pool:(bulk|fast)|cache:bulk|share:[a-z0-9][a-z0-9-]{0,40}|temp:[a-z0-9][a-z0-9-]{0,31})$ ]] || { LERR="unknown location $id"; return 1; }
  LKIND=${id%%:*}; n=${id#*:}; LLABEL=$n
  if storage_locked; then LUSABLE=no; LERR="The encrypted storage is locked: unlock it first (hs unlock)."; LREASON="storage locked"; return 1; fi
  local bt; bt=$(fm_bulk_type)
  local unusable=""
  case $LKIND in
    disk)
      [ "$bt" = snapraid ] || { LERR="This server has no data disks of an array (ZFS layout)."; return 1; }
      LDISK=$n; LPOOL=bulk; LAK=bulk; LTOP=yes; LSNAP=yes; LLOCK=yes
      dir=$(disk_dir "$n"); local mode=pool
      if fm_ismnt "$dir"; then LROOT=$dir
      elif fm_ismnt "$(detached_dir "$n")"; then LROOT=$(detached_dir "$n"); mode=detached
      else unusable="$n is not mounted (is it out for a recovery, or missing?)."; LREASON="not mounted"; fi
      if [ -z "$unusable" ]; then
        LADD=yes; LMOD=yes
        if [ -e "$fm_state_dir/recovering/$n" ]; then LADD=no; LMOD=no; LREASON="out for recovery: read only, a source"
        elif [ "$mode" = detached ]; then LADD=no; LMOD=no; LREASON="detached: out of the pool, a source only"
        elif fm_is_closed "$n"; then LADD=no; LREASON="closed: it takes no new files (hs pool bulk open $n)"; fi
      fi ;;
    pool)
      LPOOL=$n; LAK=$n; LLABEL=$n
      case $n in
        bulk)
          LTOP=yes
          if [ "$bt" = snapraid ]; then dir=$(fm_pool_root); LSNAP=yes; LLOCK=yes; else dir=$(fm_zfs_root); fi ;;
        fast) dir=$(fm_fast_root) ;;
      esac
      if fm_ismnt "$dir"; then LROOT=$dir; LADD=yes; LMOD=yes; else unusable="The pool $n is not mounted."; LREASON="not mounted"; fi ;;
    cache)
      [ "$bt" = snapraid ] || { LERR="There is no upload cache on this server (ZFS layout)."; return 1; }
      LLOCK=yes; LLABEL="bulk cache"; dir=$(fm_cache_root)
      if fm_ismnt "$dir"; then LROOT=$dir; LADD=yes; LMOD=yes; else unusable="There is no upload cache mounted."; LREASON="not mounted"; fi ;;
    share)
      local pr
      if [ "$bt" = snapraid ]; then pr=$(fm_pool_root); LSNAP=yes; LLOCK=yes; else pr=$(fm_zfs_root); fi
      LPOOL=bulk; LAK=bulk
      if ! fm_ismnt "$pr"; then unusable="The pool is not mounted."; LREASON="not mounted"
      elif [ -d "$pr/shares/$n" ] && [ ! -L "$pr/shares/$n" ]; then LROOT=$pr/shares/$n; LREL=shares/$n; LADD=yes; LMOD=yes
      elif [ -d "$pr/sensitive/$n" ] && [ ! -L "$pr/sensitive/$n" ]; then LROOT=$pr/sensitive/$n; LREL=sensitive/$n; LADD=yes; LMOD=yes
      else LERR="There is no share $n."; LUSABLE=no; LREASON="no such share"; return 1; fi ;;
    temp)
      dir=$(fm_temp_root)/$n
      if fm_ismnt "$dir"; then LROOT=$dir; LREASON="temporary disk: a source only"; else unusable="There is no temporary disk $n."; LREASON="not mounted"; fi ;;
  esac
  if [ -n "$unusable" ]; then LUSABLE=no; LERR=$unusable; return 0; fi
  LROOT=$(readlink -f -- "$LROOT")
  if [ "$LADD" = yes ] && fm_readonly "$LROOT"; then LADD=no; LMOD=no; LREASON="read-only mount"; fi
  fm_fill_size
  return 0
}

# the reason, return 0, when a and b show the same files; return 1 when they do not
fm_same_files() {
  local a=$1 b=$2 da db ka kb pa pb sa sb
  [ "$a" != "$b" ] || return 1
  fm_resolve "$a" || return 1; ka=$LKIND; da=$LDISK; pa=$LPOOL; sa=$LSNAP
  fm_resolve "$b" || return 1; kb=$LKIND; db=$LDISK; pb=$LPOOL; sb=$LSNAP
  [ "$sa" = yes ] && [ "$sb" = yes ] && [ "$pa" = "$pb" ] && [ "$pa" != - ] || return 1
  if [ "$ka" = disk ] && [ "$kb" != disk ]; then
    echo "Same files as $da: a pool disk and the pool view of its array show the same files, and copying onto the same file truncates it. Use the pool view on both sides, or two different disks."; return 0
  fi
  if [ "$kb" = disk ] && [ "$ka" != disk ]; then
    echo "Same files as $db: a pool disk and the pool view of its array show the same files, and copying onto the same file truncates it. Use the pool view on both sides, or two different disks."; return 0
  fi
  return 1
}

# protection of an entry: array | system | "" . relative = path of the folder below the location root ("" = the root)
fm_protected() {   # sets PROT
  local rel=$1 name=$2
  PROT=""
  case $name in .hs-fm-partial.*) PROT=system; return 0 ;; esac
  [ -z "$rel" ] || return 0
  [ "$LTOP" = yes ] || return 0
  if [ "$LKIND" = disk ]; then
    case $name in
      shares|sensitive) PROT=array ;;
      lost+found|*.content|*.content.lock|snapraid.*|.snapraid*|*.parity|.hs-*|.fm-*) PROT=system ;;
    esac
  else
    PROT=array
  fi
  return 0
}

# the path of an entry as the array sees it (what busy marks and the "same files" idea use): LREL/rel   (sets AREL)
fm_arel() {
  local rel=$1
  if [ -n "$LREL" ] && [ -n "$rel" ]; then AREL=$LREL/$rel
  elif [ -n "$LREL" ]; then AREL=$LREL
  else AREL=$rel; fi
}

# a share folder itself: shares/<x> or sensitive/<x> in the array view (not a folder to delete or rename by hand)
fm_is_share_root() {
  fm_arel "$1"
  [ "$LTOP" = yes ] || return 1
  [ "$LKIND" != cache ] || return 1
  [[ $AREL =~ ^(shares|sensitive)/[^/]+$ ]]
}

# a free name next to $1: "name (1).ext"
fm_free_name() {
  local p=$1 d b ext stem i=1 cand
  d=${p%/*}; b=${p##*/}
  if [[ $b == *.* ]] && [ "${b:0:1}" != . ] || [[ $b == .*.* ]]; then ext=.${b##*.}; stem=${b%.*}; else ext=""; stem=$b; fi
  while :; do
    cand="$d/$stem ($i)$ext"
    [ -e "$cand" ] || [ -L "$cand" ] || break
    i=$((i + 1))
  done
  printf '%s\n' "$cand"
}
