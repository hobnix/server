#!/usr/bin/env bash
# The guided front commands of phase 2 (hs share <name> perm, hs disk replace) and the argument templates
# of the registry, against stand-ins for manage-shares.sh and manage-pool.sh. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/fake; mkdir -p "$BIN"

cat > "$BIN/manage-shares.sh" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = --principals ]; then
  printf 'S-1-5-21-1\tHOME\\alice\tuser\nS-1-5-21-2\tHOME\\Domain Admins\tgroup\n'
elif [ "$2" = --acl ]; then
  printf 'S-1-5-21-2\tHOME\\Domain Admins\tgroup\tfull\n'
else
  echo "manage-shares $*"
fi
FAKE
cat > "$BIN/manage-pool.sh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "bulk --members") printf 'data-01\t100\tONLINE\tdata\ndata-02\t100\tMISSING\tdata\n' ;;
  "fast --members") ;;
  "--list-disks") printf 'ata-SMALL\t50\tsmall disk\nata-NEW\t200\tnew disk\n' ;;
  *) echo "manage-pool $*" ;;
esac
FAKE
export HS_MANAGE_SHARES=$BIN/manage-shares.sh HS_MANAGE_POOL=$BIN/manage-pool.sh

echo "-- share perm"
P="bash $SCRIPTS/share-perm.sh"
check_out "a name and a level become a SID and a level" "manage-shares docs --set S-1-5-21-1=write" $P docs alice=write
check_out "names with a space work, case does not matter" "S-1-5-21-2=read" $P docs "domain admins=read"
check_out "an unknown name is refused" "No user or group called 'bob'" $P docs bob=read
check_out "an unknown level is refused" "not none, read, write or full" $P docs alice=owner
check_out "--show lists the entries" "Domain Admins" $P docs --show
check_out "--dry-run is passed on" "S-1-5-21-1=read --dry-run" $P docs alice=read --dry-run

echo "-- disk replace"
R="bash $SCRIPTS/disk-replace.sh"
out=$($R --disk ata-NEW 2>&1 </dev/null)
check_out "the failed member is found" "data-02 is not ONLINE" echo "$out"
check_out "the pool command gets member and disk" "manage-pool bulk --replace data-02 --disks ata-NEW" echo "$out"
check_out "the one-liner is shown" "hs pool bulk replace data-02 --disks ata-NEW" echo "$out"
check_out "without a terminal it asks for the disk" "Say which disk" $R </dev/null
check_out "--dry-run is passed on" "ata-NEW --dry-run" $R --disk ata-NEW --dry-run </dev/null
check_out "an unknown member is refused" "not a member" $R --member nothing --disk ata-NEW </dev/null

echo "-- registry templates (real rows, stand-in scripts)"
fake=$WORK/reg; mkdir -p "$fake/lib"
cp "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/job.sh "$fake/lib/"; cp -r "$SCRIPTS"/lib/i18n "$fake/lib/"
for s in manage-pool health disk-health temp-disk disk-replace create-share sync-shares share-perm share-cache manage-shares manage-ct manage-users status users-show ct-access ct-guided user-guided; do printf 'echo "%s $*"\n' "$s" > "$fake/$s.sh"; done
cp "$SCRIPTS/lib/registry.tsv" "$fake/lib/"
F="env HS_CALLER=t bash $fake/lib/hs.sh"
check_eq "disk <disk> test short" "disk-health --test short sda" "$($F disk sda test short)"
check_eq "disk <disk> health" "disk-health sda" "$($F disk sda health)"
check_eq "disk <disk> results" "disk-health --results sda" "$($F disk sda results)"
check_eq "share <share> rename" "manage-shares docs --rename new" "$($F share docs rename new)"
check_eq "share <share> cache on" "share-cache docs on" "$($F share docs cache on)"
check_eq "share <share> perm alice=read" "share-perm docs alice=read" "$($F share docs perm alice=read)"
check_eq "share repair" "sync-shares --fix-owner" "$($F share repair)"
check_eq "disk temp mount /dev/sdb1" "temp-disk mount /dev/sdb1" "$($F disk temp mount /dev/sdb1)"
check_eq "disk temp lists" "temp-disk list" "$($F disk temp)"

echo "-- containers and users (templates)"
check_eq "ct list" "status " "$($F ct list)"
check_eq "ct add" "ct-guided add web --docker --ram 1024" "$($F ct add web --docker --ram 1024)"
check_eq "ct <ct> start" "manage-ct web --start" "$($F ct web start)"
check_eq "ct <ct> set" "manage-ct web --set ram=2048 cpu=2" "$($F ct web set ram=2048 cpu=2)"
check_eq "ct <ct> ip" "ct-guided ip web 10.10.95.25" "$($F ct web ip 10.10.95.25)"
check_eq "ct <ct> snapshot with a label" "ct-guided snapshot web before-update" "$($F ct web snapshot before-update)"
check_eq "ct <ct> storage add" "manage-ct web --add-storage shares media /mnt/media --readonly" "$($F ct web storage add shares media /mnt/media --readonly)"
check_eq "ct <ct> storage list" "manage-ct web --storage" "$($F ct web storage list)"
check_eq "ct <ct> exec" "ct-access web exec ls -l" "$($F ct web exec ls -l)"
check_eq "user add" "user-guided add bob --full Bob B" "$($F user add bob --full 'Bob B')"
check_eq "user <user> passwd" "manage-users --password bob" "$($F user bob passwd)"
check_eq "user <user> lock" "user-guided lock bob" "$($F user bob lock)"
check_eq "user <user> join <group>" "manage-users --member family bob add" "$($F user bob join family)"
check_eq "user <user> leave <group>" "manage-users --member family bob remove" "$($F user bob leave family)"
check_eq "group <group> remove" "manage-users --group-delete family" "$($F group family remove)"
check_eq "user list" "users-show users" "$($F user list)"
check_eq "group <group> show" "users-show groups family" "$($F group family show)"

echo "-- sys rows with the name after the verb"
check_eq "sys pool info <pool>" "manage-pool bulk --info" "$($F sys pool info bulk)"
check_eq "sys pool info alone" "manage-pool --info" "$($F sys pool info)"
check_eq "sys pool members <pool>" "manage-pool bulk --members" "$($F sys pool members bulk)"
check_eq "sys shares acl <share>" "manage-shares docs --acl" "$($F sys shares acl docs)"
check_eq "sys ct storage <ct>" "manage-ct web --storage" "$($F sys ct storage web)"
check_eq "sys ct snapshots <ct>" "manage-ct web --snapshots" "$($F sys ct snapshots web)"
check_eq "sys ct users <ct>" "manage-ct web --users" "$($F sys ct users web)"
check_eq "sys health next" "health next" "$($F sys health next)"

echo "-- ct-access (stand-in for incus)"
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = info ] && exit 0
echo "incus $*"
FAKE
chmod +x "$BIN/incus"
export HS_INCUS=$BIN/incus
A="bash $SCRIPTS/ct-access.sh"
check_eq "shell" "incus exec web -- su -l" "$($A web shell)"
check_eq "exec" "incus exec web -- uname -a" "$($A web exec uname -a)"
check_out "logs" "journalctl -n 50" $A web logs 50
check_out "a bad number of lines is refused" "usage" $A web logs many
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/incus-none"; chmod +x "$BIN/incus-none"
check_out "an unknown instance is refused" "No instance called" env HS_INCUS=$BIN/incus-none $A nothere shell

echo "-- users-show (stand-in for manage-users)"
cat > "$BIN/manage-users-fake.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --list) printf 'alice\tAlice A\tenabled\tfamily\nbob\tBob B\tdisabled\t\n' ;;
  --groups) printf 'family\talice\n' ;;
esac
FAKE
export HS_MANAGE_USERS=$BIN/manage-users-fake.sh
U="bash $SCRIPTS/users-show.sh"
check_out "users listed" "Alice A" $U users
check_out "one user" "disabled" $U users bob
if $U users bob 2>&1 | grep -q Alice; then fail "one user only"; else pass "one user only"; fi
check_out "groups listed" "family" $U groups
check_out "an unknown user is reported" "No user called 'zed'" $U users zed

finish
