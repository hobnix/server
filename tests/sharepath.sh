#!/usr/bin/env bash
# scripts/lib/sharepath.sh (where a share lives: bulk or fast). Folders in a temp dir, fake net and zfs: no root, no disks.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_BULK=$WORK/bulk HS_FAST=$WORK/fast
mkdir -p "$WORK/bulk/shares/media" "$WORK/bulk/sensitive/vault" "$WORK/fast/shares/notes" "$WORK/fast/sensitive/keys"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/zfs"; chmod +x "$WORK/zfs"; export HS_ZFS=$WORK/zfs
printf '#!/usr/bin/env bash\n[ "$*" = "conf listshares" ] && printf "media\nhidden\n"\nexit 0\n' > "$WORK/net"; chmod +x "$WORK/net"; export HS_NET=$WORK/net
echo zfs > "$WORK/bulk-type"; export HS_BULK_TYPE_FILE=$WORK/bulk-type
# shellcheck source=scripts/lib/sharepath.sh
. "$SCRIPTS/lib/sharepath.sh"

echo "-- roots and tiers"
check_eq "bulk root" "$WORK/bulk" "$(share_root bulk)"
check_eq "fast root" "$WORK/fast" "$(share_root fast)"
check_eq "both tiers (fast has folders)" "bulk fast" "$(share_tiers | tr '\n' ' ' | sed 's/ $//')"
rmdir "$WORK/fast/shares/notes" "$WORK/fast/shares" "$WORK/fast/sensitive/keys" "$WORK/fast/sensitive"
check_eq "bulk only without fast" "bulk" "$(share_tiers)"
mkdir -p "$WORK/fast/shares/notes" "$WORK/fast/sensitive/keys"

echo "-- dir, kind, tier"
check_eq "bulk dir" "$WORK/bulk/shares/media" "$(share_dir media)"
check_eq "fast dir" "$WORK/fast/shares/notes" "$(share_dir notes)"
check_eq "fast sensitive kind" "sensitive" "$(share_kind keys)"
check_eq "fast tier" "fast" "$(share_tier keys)"
check_eq "bulk tier" "bulk" "$(share_tier vault)"
check_eq "unknown share" 1 "$(share_dir nothere >/dev/null 2>&1; echo $?)"

echo "-- dataset"
check_eq "bulk dataset" "bulk/shares/media" "$(share_dataset media)"
check_eq "fast dataset" "fast/sensitive/keys" "$(share_dataset keys)"
echo snapraid > "$WORK/bulk-type"
check_eq "snapraid bulk has no dataset" 1 "$(share_dataset media >/dev/null 2>&1; echo $?)"
check_eq "snapraid, fast still a dataset" "fast/shares/notes" "$(share_dataset notes)"

echo "-- kind of a path"
check_eq "bulk shares" shares "$(share_kind_of_path "$WORK/bulk/shares/x")"
check_eq "fast sensitive" sensitive "$(share_kind_of_path "$WORK/fast/sensitive/x")"
check_eq "elsewhere" other "$(share_kind_of_path /mnt/x/y)"

echo "-- name taken"
check_eq "folder on bulk" 0 "$(share_name_taken media; echo $?)"
check_eq "folder on fast, other case" 0 "$(share_name_taken NOTES; echo $?)"
check_eq "only in Samba" 0 "$(share_name_taken hidden; echo $?)"
check_eq "free" 1 "$(share_name_taken free; echo $?)"

echo "-- cleanup, delete and restore with a share on fast"
export HS_PLAIN=1 HS_LANG=en HS_LOCK=$WORK/lock HS_LOCKED_FLAG=$WORK/no-flag
unset HS_CALLER HS_GUIDED_TTY
printf '#!/usr/bin/env bash\ncase "$*" in\n  "conf listshares") printf "gonefast\nlostroot\n" ;;\n  "conf getparm gonefast path") echo %s/fast/shares/gonefast ;;\n  "conf getparm lostroot path") echo %s/fast/gone-root/shares/lostroot ;;\n  "conf getparm notes path") echo %s/fast/shares/gone-notes ;;\n  *) exit 0 ;;\nesac\n' "$WORK" "$WORK" "$WORK" > "$WORK/net2"
chmod +x "$WORK/net2"
if ! command -v flock >/dev/null 2>&1; then mkdir -p "$WORK/stub"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/stub/flock"; chmod +x "$WORK/stub/flock"; export PATH="$WORK/stub:$PATH"; fi
out=$(HS_NET=$WORK/net2 bash "$SCRIPTS/share-cleanup.sh" --dry-run 2>&1 || true)
check_out "cleanup: a gone fast folder is listed" "gonefast" echo "$out"
check_eq "cleanup: a share whose fast root is missing is not listed" "" "$(grep -c lostroot <<<"$out" | sed 's/^0$//')"
out=$(HS_NET=$WORK/net2 bash "$SCRIPTS/share-delete.sh" gonefast --dry-run 2>&1 || true)
check_out "delete: a gone fast folder is only a dead Samba share" "net conf delshare gonefast" echo "$out"
# restore of a share whose folder is gone: the registry knows it was on fast
printf '#!/usr/bin/env bash\necho "$@" > %s/restore-args\n' "$WORK" > "$WORK/backup-stub"; chmod +x "$WORK/backup-stub"
mkdir -p "$WORK/bulk/shares/restored"
mkdir -p "$WORK/nb"; cp "$WORK/net2" "$WORK/nb/net"
PATH="$WORK/nb:$PATH" HS_BACKUP=$WORK/backup-stub bash "$SCRIPTS/share-restore.sh" gonefast --snapshot latest --yes >/dev/null 2>&1 || true
check_eq "restore: a gone fast share is looked up under /fast, not /bulk" "restore latest $WORK/fast/shares/gonefast --to $WORK/bulk/shares/restored" "$(cat "$WORK/restore-args" 2>/dev/null)"
finish
