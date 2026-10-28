#!/usr/bin/env bash
# The container commands that had no test of their own: hs ct list (status.sh), hs mac, hs ct <ct> shell|exec|logs|console
# (ct-access.sh), and the plain forms of hs ct <ct> start|stop|restart|set|update|storage add|remove
# (manage-ct.sh, shown with --dry-run). Fake incus on PATH. Needs jq (always there in CI), no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
BIN=$WORK/bin; mkdir -p "$BIN"
export LOG=$WORK/incus.log; : > "$LOG"

if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: container tests not run"; finish; exit $?; fi

cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1" in
  info) case "$2" in web|db|vm1) exit 0 ;; *) exit 1 ;; esac ;;
  list)
    if [ "$2" = -c ]; then printf 'web\ndb\nvm1\n'; else cat <<'JSON'
[{"name":"web","type":"container","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet6","address":"fe80::1"},{"family":"inet","address":"10.10.95.21"}]}}},
  "expanded_devices":{"eth0":{"hwaddr":"00:16:3e:00:00:01"}}},
 {"name":"db","type":"container","status":"Stopped","state":{"network":null},"expanded_devices":{"eth0":{"name":"eth0"}}},
 {"name":"vm1","type":"virtual-machine","status":"Running","state":{"network":{"enp5s0":{"addresses":[{"family":"inet","address":"10.10.95.40"}]}}},
  "expanded_devices":{"eth0":{"hwaddr":"00:16:3e:00:00:03"}}}]
JSON
    fi ;;
  storage) exit 1 ;;   # no volume exists yet
  profile) echo '[{"name":"default","description":"Default","devices":{"root":{"type":"disk"},"eth0":{"type":"nic","network":"incusbr0"}}},{"name":"home","description":"VLAN 95","devices":{"eth0":{"type":"nic","parent":"br-home","nictype":"bridged"}}},{"name":"nonet","description":"x","devices":{"root":{"type":"disk"}}}]' ;;
  query) echo '{"type":"container","expanded_devices":{}}' ;;
  config)
    case "$2" in
      device)
        case "$3" in
          get) [ "$4" = web ] && [ "$5" = eth0 ] && echo "00:16:3e:00:00:01" || exit 1 ;;   # only web is pinned
          override|set) [ "$4" != vm1 ] || exit 1 ;;                     # the NIC of a running VM can't change
        esac ;;
      get) case "$3" in db) echo "00:16:3e:00:00:02" ;; vm1) echo "00:16:3e:00:00:03" ;; *) echo "" ;; esac ;;
    esac ;;
  exec) shift; case "$*" in *"command -v update"*) exit 1 ;; esac; echo "ran: $*" ;;
  console) echo "console $2" ;;
esac
FAKE
chmod +x "$BIN/incus"
export PATH=$BIN:$PATH

echo "-- hs ct list (status.sh)"
out=$(bash "$SCRIPTS/status.sh")
check_out "header" "^Name +State +IPv4 +MAC" echo "$out"
check_out "a running container: IPv4 (not IPv6) and pinned MAC" "^web +Running +10\.10\.95\.21 +00:16:3e:00:00:01" echo "$out"
check_out "a stopped container has no address and no pinned MAC" "^db +Stopped +- +not pinned" echo "$out"
check_out "a VM is read from enp5s0" "^vm1 +Running +10\.10\.95\.40" echo "$out"

echo "-- hs mac"
: > "$LOG"
out=$(bash "$SCRIPTS/mac.sh" 2>&1)
check_out "a pinned one is left alone" "web: 00:16:3e:00:00:01 \(already pinned\)" echo "$out"
check_out "an unpinned one gets its MAC" "db: 00:16:3e:00:00:02 pinned" echo "$out"
check "the pin was set with override" grep -q 'incus config device override db eth0 hwaddr=00:16:3e:00:00:02' "$LOG"
check_out "a running VM can't be pinned: the hint says what to do" "vm1: could not pin the MAC while it runs" echo "$out"
check_out "a hint for the fixed IP follows" "fixed IP" echo "$out"
: > "$LOG"
out=$(bash "$SCRIPTS/mac.sh" web 2>&1)
check_eq "with a name only that one is looked at" "1" "$(grep -c 'incus config device get' "$LOG")"
check_out "and it is already pinned" "already pinned" echo "$out"

echo "-- hs ct <ct> shell|exec|logs|console (ct-access.sh)"
A="env HS_INCUS=$BIN/incus bash $SCRIPTS/ct-access.sh"
: > "$LOG"
check_out "exec runs the command inside" "ran: web -- ls /etc" $A web exec ls /etc
check_out "shell is a login shell" "ran: web -- su -l" $A web shell
check_out "logs asks the journal for 20 lines" "journalctl -n 20 --no-pager" $A web logs 20
check_out "logs without a number reads 100" "journalctl -n 100 --no-pager" $A web logs
check_out "console" "console web" $A web console
check_out "an unknown instance is named" "No instance called 'nope'" $A nope shell
check_out "logs wants a number" "usage" $A web logs many
check_out "exec wants a command" "usage" $A web exec
check_out "an unknown verb prints the usage" "usage: hs ct" $A web dance

echo "-- manage-ct plain forms (--dry-run prints the command)"
C="bash $SCRIPTS/manage-ct.sh"
check_eq "start" "  incus start web" "$($C web --start --dry-run)"
check_eq "stop" "  incus stop web" "$($C web --stop --dry-run)"
check_eq "restart" "  incus restart web" "$($C web --restart --dry-run)"
check_eq "set ram and cpu" "  incus config set web limits.memory=2048MiB
  incus config set web limits.cpu=2" "$($C web --set ram=2048 cpu=2 --dry-run)"
check_eq "set ram none removes the limit" "  incus config unset web limits.memory" "$($C web --set ram=none --dry-run)"
check_eq "set autostart" "  incus config set web boot.autostart=false" "$($C web --set autostart=no --dry-run)"
check_out "an unknown setting is refused" "unknown setting 'colour'" $C web --set colour=red --dry-run
out=$($C web --update --dry-run)
check_out "update takes a snapshot first" "incus snapshot create web before-update-[0-9]{8}-[0-9]{4}" echo "$out"
check_out "then updates the packages" "apt-get.+update" echo "$out"
check_eq "storage add (a fast volume, read-only)" "  incus storage volume create default data
  incus storage volume attach default data web data /data
  incus config device set web data readonly=true" "$($C web --add-storage fast data /data --readonly --dry-run)"
check_eq "storage remove" "  incus config device remove web data" "$($C web --remove-storage data --dry-run | head -n1)"
check_out "the path must be absolute" "must start with /" $C web --add-storage fast data data --dry-run
check_out "a bad kind is refused" "unknown kind 'tape'" $C web --add-storage tape x /x --dry-run
check_eq "--profiles lists the profiles that have a NIC" "default	incusbr0	Default
home	br-home	VLAN 95" "$($C --profiles)"
finish
