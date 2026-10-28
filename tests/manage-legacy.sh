#!/usr/bin/env bash
# manage-ct.sh and manage-users.sh after their move to lib/ui.sh: the lines the interface reads are unchanged,
# the messages for people use the styled helpers (plain text here), failures still exit 1. Fake incus, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
LOG=$WORK/incus.log; : > "$LOG"; export LOG
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1" in
  info) [ "$2" = web ] || [ "$2" = dc1 ] || exit 1 ;;
  list)
    if [ "$2" = '^dc1$' ]; then echo RUNNING
    else cat <<'JSON'
[{"name":"web","type":"container","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","address":"10.10.95.21"}]}},"memory":{"usage":1},"cpu":{"usage":2}},
  "config":{"limits.memory":"512MiB","boot.autostart":"true"},"expanded_devices":{"eth0":{"hwaddr":"00:16:3e:00:00:01"},"root":{"size":"10GiB"}},
  "snapshots":[{"created_at":"2026-10-01T10:00:00Z"}]}]
JSON
    fi ;;
  query)
    case "$2" in
      */snapshots*) echo '[{"name":"web/snap-a","created_at":"2026-10-01T10:00:00Z"},{"name":"web/snap-b","created_at":"2026-10-02T11:30:00Z"}]' ;;
      /1.0/instances/web) echo '{"type":"container","expanded_devices":{"eth0":{"hwaddr":"00:16:3e:00:00:01"},"data":{"type":"disk","pool":"default","source":"vol","path":"/data"}}}' ;;
    esac ;;
  exec)
    shift 2   # exec, name
    [ "$1" != -t ] || shift
    shift     # --
    case "$1" in
      ldbsearch)
        case "$*" in
          *person*) printf 'dn: CN=Anna,CN=Users,DC=ad\nsAMAccountName: anna\ndisplayName: Anna A\nuserAccountControl: 512\nprimaryGroupID: 513\n\n'
                    [ -z "${FAKE_ADMIN:-}" ] || printf 'dn: CN=Administrator,CN=Users,DC=ad\nsAMAccountName: Administrator\nuserAccountControl: 512\nprimaryGroupID: 513\n\n' ;;
          *) printf 'dn: CN=Domain Users,CN=Users,DC=ad\nsAMAccountName: Domain Users\n\ndn: CN=Staff,CN=Users,DC=ad\nsAMAccountName: Staff\nmember: CN=Anna,CN=Users,DC=ad\n\n' ;;
        esac ;;
      *) echo "on dc: $*" ;;
    esac ;;
esac
FAKE
chmod +x "$BIN/incus"
export PATH="$BIN:$PATH"
CT="bash $SCRIPTS/manage-ct.sh"; US="bash $SCRIPTS/manage-users.sh"

echo "-- manage-ct: what the interface reads is unchanged"
check_eq "--list: one line per instance, tab separated" "web	ct	Running	10.10.95.21	512MiB	-	true	yes	false	10GiB	1	2026-10-01	1	2	0	-" "$($CT --list)"
check_eq "--snapshots" "snap-a	2026-10-01 10:00
snap-b	2026-10-02 11:30" "$($CT web --snapshots)"
check_eq "--storage" "data	fast	volume vol	/data	write	-" "$($CT web --storage 2>/dev/null)"
check_eq "a dry run prints the command, indented, as before" "  incus snapshot create web nightly" "$($CT web --snapshot nightly --dry-run)"
check_eq "a dry-run delete lists what stays" "Delete 'web' with all its snapshots. Attached storage stays:
  volume vol -> /data
  incus delete -f web" "$($CT web --delete --dry-run)"

echo "-- manage-ct: messages for people"
check_out "unknown instance" "✗ 'nope' does not exist\." $CT nope --start
check_eq "and exit status 1" "1" "$($CT nope --start >/dev/null 2>&1; echo $?)"
check_out "an existing name" "✗ 'web' already exists\." $CT --create web
check_out "a number is checked" "✗ RAM must be a number, got 'abc'" $CT web --set ram=abc
check_out "a bad storage name" "✗ invalid storage name" $CT web --add-storage fast 'bad name' /data
check_out "a restore says where it ends up" "✓ 'web' is back at 'snap-b'" $CT web --restore snap-b
check_out "a typed delete asks and deletes" "✓ Deleted\." bash -c "echo web | bash $SCRIPTS/manage-ct.sh web --delete"
check_out "the wrong name cancels" "✗ cancelled" bash -c "echo nope | bash $SCRIPTS/manage-ct.sh web --delete"
check_out "German" "✗ 'nope' gibt es nicht\." env HS_LANG=de $CT nope --start

echo "-- manage-users"
check_eq "--list stays: name, full name, state, groups" "anna	Anna A	enabled	Domain Users,Staff" "$($US --list)"
check_eq "--groups stays: name, members" "Domain Users	anna
Staff	anna" "$($US --groups)"
check_out "a user that exists" "✗ A user called 'anna' exists already\." $US --add anna
check_out "an invalid login name" "✗ Invalid login name 'Bad Name'" $US --add 'Bad Name'
check_out "no such user" "✗ No user called 'zed'\." $US --password zed
check_out "no such group" "✗ No group called 'Nope'\." $US --member Nope anna add
check_out "Administrator can't be locked" "✗ Not possible: locking Administrator" env FAKE_ADMIN=1 $US --disable Administrator
check_out "a dry-run delete keeps the plain lines" "on dc1: samba-tool user delete anna" $US --delete anna --dry-run
check_out "a delete asks for the name" "✗ cancelled" bash -c "echo nope | bash $SCRIPTS/manage-users.sh --delete anna"
check_out "German" "✗ Keinen Benutzer namens|✗ Kein Benutzer namens|✗ Es gibt keinen Benutzer namens|No user called" env HS_LANG=de $US --password zed

finish
