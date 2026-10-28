#!/usr/bin/env bash
# The guided dialogues ct-guided.sh and user-guided.sh, against stand-ins for manage-ct.sh, manage-users.sh,
# manage-shares.sh, net-ip.sh and incus. No root needed. Answers come from stdin (HS_GUIDED_TTY=1 = "there is a
# terminal"), the plain fallback of ui.sh reads them line by line.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
B=$WORK/fake; mkdir -p "$B"

cat > "$B/manage-ct.sh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"--snapshots") printf 'snap-a\t2026-10-01 10:00\nsnap-b\t2026-10-02 10:00\n' ;;
  *"--users") printf 'www-data\t33\t33\tnginx\n' ;;
  *"--storage") printf 'media\tdisk\t/mnt/media\n' ;;
  *) echo "manage-ct $*" ;;
esac
FAKE
cat > "$B/manage-shares.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'media\tshare\t/bulk/shares/media\toff\t-\t\nphotos\tsensitive\t/bulk/sensitive/photos\toff\t-\t\n'
FAKE
cat > "$B/net-ip.sh" <<'FAKE'
#!/usr/bin/env bash
echo "net-ip $*"
FAKE
cat > "$B/incus" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "info ghost"|"info web2") exit 1 ;;
  "info "*) exit 0 ;;
  "config get") case "$4" in limits.memory) echo 1024MiB ;; limits.cpu) echo 2 ;; boot.autostart) echo true ;; security.nesting) echo false ;; esac ;;
  "config device") echo 20GiB ;;
esac
FAKE
cat > "$B/manage-users.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --list) printf 'alice\tAlice A\tenabled\tfamily\nbob\tBob B\tdisabled\t\n' ;;
  --groups) printf 'family\talice\nkids\t\nadmins\talice\n' ;;
  *) echo "manage-users $*" ;;
esac
FAKE
chmod +x "$B"/*
export HS_MANAGE_CT=$B/manage-ct.sh HS_MANAGE_SHARES=$B/manage-shares.sh HS_NET_IP=$B/net-ip.sh HS_INCUS=$B/incus HS_MANAGE_USERS=$B/manage-users.sh
C="bash $SCRIPTS/ct-guided.sh"
U="bash $SCRIPTS/user-guided.sh"
tty_() { env HS_GUIDED_TTY=1 "$@"; }

echo "-- ct add"
check_out "all answers as options" "manage-ct --create web2 --ram 2048 --docker --cpu 2 --disk 30 --ip 10.10.95.40" $C add --kind docker --name web2 --ram 2048 --cpu 2 --disk 30 --ip 10.10.95.40 --yes
check_out "the old form: name and --docker" "manage-ct --create web2 --ram 1024 --docker" $C add web2 --docker --yes
check_out "the old --profile option is passed on" "manage-ct --create web2 --ram 1024 --profile home" $C add web2 --profile home --yes
check_out "a name only = an empty container with defaults" "manage-ct --create web2 --ram 1024" $C add web2 --yes
check_out "a vm gets 2048 MB by default" "manage-ct --create web2 --ram 2048 --vm" $C add web2 --vm --yes
check_out "no terminal and nothing given: asks for the option" "Missing: --kind" $C add
check_out "a bad name is refused" "not a good name" $C add Web_2 --yes
check_out "an existing name is refused" "exists already" $C add web --yes
check_out "without --yes and no terminal nothing runs" "without --yes" $C add web2
out=$(printf '2\nweb2\n512\n\n\n\ny\n' | tty_ $C add 2>&1)   # kind 2 = docker, then name, ram, cpu, disk, ip, confirm
check_out "the dialogue: kind, name, memory..." "manage-ct --create web2 --ram 512 --docker" echo "$out"
check_out "and shows the next-time one-liner" "hs ct add --kind docker --name web2 --ram 512" echo "$out"

echo "-- ct edit"
check_out "options become one --set" "manage-ct web --set ram=2048 autostart=no" $C edit web --ram 2048 --autostart no --yes
check_out "no change = nothing to do" "Nothing to change" bash -c "printf '\n\n\n\n\n' | HS_GUIDED_TTY=1 bash $SCRIPTS/ct-guided.sh edit web"
out=$(printf '2048\n\n\n\nyes\ny\n' | tty_ $C edit web 2>&1)
check_out "only the changed values are applied" "manage-ct web --set ram=2048 docker=yes" echo "$out"
check_out "an unknown instance is refused" "No instance called" $C edit ghost --ram 1 --yes

echo "-- ct snapshot"
check_out "a label creates one" "manage-ct web --snapshot nightly" $C snapshot web nightly
check_out "restore with a warning" "newer snapshots are deleted" $C snapshot web --restore snap-a --yes
check_out "and runs the restore" "manage-ct web --restore snap-a" $C snapshot web --restore snap-a --yes
check_out "delete" "manage-ct web --delete-snapshot snap-b" $C snapshot web --delete snap-b --yes
out=$(printf '%s\n' 2 1 web | tty_ $C snapshot web 2>&1)    # menu: restore, first snapshot, typed name of the instance
check_out "the menu lists the snapshots" "snap-b" echo "$out"
check_out "and restores the chosen one" "manage-ct web --restore snap-a" echo "$out"

echo "-- ct storage"
check_out "a share, read-only, as a user" "manage-ct web --add-storage shares media /mnt/media --readonly --as 33:33" $C storage web --kind shares --source media --path /mnt/media --readonly --as 33:33 --yes
check_out "a fast volume" "manage-ct web --add-storage fast web-data /data" $C storage web --kind fast --name web-data --path /data --yes
out=$(printf '1\n1\n\n1\n1\ny\ny\n' | tty_ $C storage web 2>&1)
check_out "the dialogue lists the shares of that kind" "manage-ct web --add-storage shares media /mnt/media" echo "$out"
check_out "no terminal: asks for the option" "Missing: --kind" $C storage web

echo "-- ct ip"
check_out "an address sets it" "manage-ct web --set ip=10.10.95.25" $C ip web 10.10.95.25
check_out "a bad address is refused" "not an IPv4" $C ip web nonsense
out=$(printf '10.10.95.26\n' | tty_ $C ip web 2>&1)
check_out "asked: shows the current one first" "net-ip web show" echo "$out"
check_out "and sets the new one" "manage-ct web --set ip=10.10.95.26" echo "$out"
check_out "empty answer = unchanged" "Unchanged" bash -c "printf '\n' | HS_GUIDED_TTY=1 bash $SCRIPTS/ct-guided.sh ip web"

echo "-- user add"
check_out "creates and adds to groups" "manage-users --member kids carol add" $U add carol --full "Carol C" --groups kids --yes
check_out "the user is created with the full name" "manage-users --add carol --full Carol C" $U add carol --full "Carol C" --groups kids --yes
check_out "an existing login is refused" "exists already" $U add alice --yes
check_out "a bad login is refused" "not a good login" $U add Carol --yes
check_out "no terminal: asks for the option" "Missing: --name" $U add
out=$(printf 'carol\nCarol C\n2\ny\n' | tty_ $U add 2>&1)   # login, full name, group number 2 (kids), confirm
check_out "the dialogue creates the user" "manage-users --add carol --full Carol C" echo "$out"
check_out "and puts it into the chosen group" "manage-users --member kids carol add" echo "$out"

echo "-- user lock"
check_out "an unlocked account is locked" "manage-users --disable alice" $U lock alice --yes
check_out "a locked account is unlocked" "manage-users --enable bob" $U lock bob --yes
check_out "it says what it will do" "will be locked" $U lock alice --yes
check_out "an unknown user is refused" "No user called" $U lock zed --yes

echo "-- user groups"
check_out "the difference is applied" "manage-users --member kids alice add" $U groups alice --set family,kids --yes
check_out "and removals too" "manage-users --member admins alice remove" $U groups alice --set family,kids --yes
check_out "same groups = nothing to change" "Nothing to change" $U groups alice --set family,admins --yes
out=$(printf '1 2\ny\n' | tty_ $U groups bob 2>&1)       # bob is in no group: tick family and kids
check_out "the multi-select shows the groups" "family" echo "$out"
check_out "and adds the ticked ones" "manage-users --member kids bob add" echo "$out"

echo "-- group add"
check_out "a group" "manage-users --group-add friends" $U group-add friends
check_out "a bad name is refused" "not a good group name" $U group-add "!!"
check_out "asked" "manage-users --group-add friends" bash -c "printf 'friends\n' | HS_GUIDED_TTY=1 bash $SCRIPTS/user-guided.sh group-add"

echo "-- share restore"
cat > "$B/backup.sh" <<'FAKE'
#!/usr/bin/env bash
echo "backup $*"
FAKE
cat > "$B/create-share.sh" <<'FAKE'
#!/usr/bin/env bash
echo "create-share $*"; mkdir -p "$HS_BULK/shares/$1"
FAKE
chmod +x "$B/backup.sh" "$B/create-share.sh"
export HS_BACKUP=$B/backup.sh HS_CREATE_SHARE=$B/create-share.sh HS_BULK=$WORK/bulk
mkdir -p "$HS_BULK/shares/docs"
R="bash $SCRIPTS/share-restore.sh"
check_out "restores the whole share from latest" "backup restore latest $HS_BULK/shares/docs --to $HS_BULK/shares/restored" $R docs --yes
check_out "the target share is created when missing" "create-share restored" bash -c "rm -rf $HS_BULK/shares/restored; $R docs --yes"
check_out "a folder inside the share and a snapshot" "backup restore ab12cd34 $HS_BULK/shares/docs/2024/tax --to" $R docs 2024/tax --snapshot ab12cd34 --yes
check_out "a bad snapshot id is refused" "not a snapshot id" $R docs --snapshot "x y" --yes
check_out "no terminal and no --yes: nothing happens" "without --yes" $R docs
mkdir -p "$HS_BULK/sensitive/photos"
check_out "a sensitive share is found" "$HS_BULK/sensitive/photos" $R photos --yes
out=$(printf '\n\ny\n' | HS_GUIDED_TTY=1 $R docs 2>&1)
check_out "asked: folder, snapshot, confirmation" "backup restore latest $HS_BULK/shares/docs" echo "$out"

echo "-- share snapshots"
cat > "$B/share-snap.sh" <<'FAKE'
#!/usr/bin/env bash
if [ "$2" = snapshots ]; then printf 'first\t2026-10-01\t1K\nsecond\t2026-10-02\t1K\n'; exit 0; fi
echo "share-snap $*"
FAKE
cat > "$B/snapshots-auto.sh" <<'FAKE'
#!/usr/bin/env bash
echo "snapshots-auto $*"
FAKE
chmod +x "$B/share-snap.sh" "$B/snapshots-auto.sh"
export HS_SHARE_SNAP=$B/share-snap.sh HS_SNAPSHOTS_AUTO=$B/snapshots-auto.sh
G="bash $SCRIPTS/share-snap-guided.sh"
check_out "snapshot with a name" "share-snap docs snapshot before" $G docs snapshot before --yes
check_out "snapshot without a name uses the default" "share-snap docs snapshot" $G docs snapshot --yes
check_out "snapshot: a bad name is refused" "not a snapshot name" $G docs snapshot 'a b' --yes
check_out "snapshot without a terminal and --yes: nothing happens" "without --yes" $G docs snapshot
out=$(printf 'mine\n' | tty_ $G docs snapshot 2>&1)
check_out "snapshot asks for the name" "share-snap docs snapshot mine" echo "$out"
check_out "rollback with a name passes --yes on" "share-snap docs rollback first --yes" $G docs rollback first --yes
check_out "rollback without --yes and without a terminal is refused" "without --yes" $G docs rollback first
out=$(printf '2\n' | tty_ $G docs rollback 2>&1)    # newest first: 1 = second, 2 = first
check_out "rollback offers the list, newest first" "1) second" echo "$out"
check_out "and the chosen one goes to share-snap.sh, which asks itself" "share-snap docs rollback first" echo "$out"
check_out "auto on" "snapshots-auto docs on" $G docs auto on --yes
check_out "auto off" "snapshots-auto docs off" $G docs auto off --yes
check_out "auto without on|off and --yes is a usage error" "usage" $G docs auto --yes
check_out "auto without a terminal is refused" "without --yes" $G docs auto on
out=$(printf '2\n' | tty_ $G docs auto 2>&1)
check_out "auto asks on or off" "snapshots-auto docs off" echo "$out"
check_out "an unknown action is a usage error" "usage" $G docs frobnicate

finish
