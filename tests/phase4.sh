#!/usr/bin/env bash
# config, system, net ip, health, report, migrate and first-run (phase 4 and 5), against stand-ins. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_STATE_DIR"
S=$SCRIPTS

echo "-- config"
M=$WORK/machine.toml
printf 'hostName = "x"\n\n# language = "de"\n\n# gpu = "nvidia"\n\nmetrics = false\n' > "$M"
export HS_MACHINE_FILE=$M
C="bash $S/config.sh"
$C set language de >/dev/null 2>&1
$C set keyMap de >/dev/null 2>&1
check_eq "a commented option is switched on" 'keyMap = "de"' "$(grep -E '^[[:space:]]*keyMap' "$M")"
check_eq "a runtime setting goes to its own file, not machine.toml" "de|0" "$(cat "$HS_STATE_DIR/settings/language")|$(grep -c '^language' "$M" || true)"
$C set metrics true >/dev/null 2>&1
check_eq "an active option is replaced" "true" "$($C get metrics)"
$C set notifyUrl https://ntfy.sh/t >/dev/null 2>&1
check_eq "the push address goes to its old file" "https://ntfy.sh/t" "$(cat "$HS_STATE_DIR/notify-url")"
check_eq "and is there" "https://ntfy.sh/t" "$($C get notifyUrl)"
$C set notifyUrl none >/dev/null 2>&1
check_eq "none removes it" "no" "$(test -e "$HS_STATE_DIR/notify-url" && echo yes || echo no)"
$C set gpu intel >/dev/null 2>&1; $C set gpu none >/dev/null 2>&1
check_eq "gpu none comments the line out" "# gpu = \"intel\"" "$(grep 'gpu' "$M" | head -n1)"
check_out "a bad value is refused" "must be one of" $C set language fr
check_out "a bad URL is refused" "must be a URL" $C set notifyUrl ftp://x
check_out "an unknown key is refused" "not a key" $C set hostName y
check_eq "the old file is kept" "yes" "$(test -f "$HS_STATE_DIR/machine.toml.before-config" && echo yes)"
check_eq "--dry-run changes nothing" "true" "$($C set metrics false --dry-run >/dev/null 2>&1; $C get metrics)"
check_out "list shows the keys" "backupNewShares" $C list

echo "-- system"
cat > "$BIN/nixos-rebuild" <<'FAKE'
#!/usr/bin/env bash
echo "nixos-rebuild $*" >> "$(dirname "$0")/calls.log"
FAKE
cat > "$BIN/nix-collect-garbage" <<'FAKE'
#!/usr/bin/env bash
echo "nix-collect-garbage $*" >> "$(dirname "$0")/calls.log"
FAKE
chmod +x "$BIN/nixos-rebuild" "$BIN/nix-collect-garbage"
check_out "info shows the host" "Host" bash "$S/system.sh" info
check_out "gc asks, and runs with the days" "nix-collect-garbage --delete-older-than 14d" bash -c "rm -f $BIN/calls.log; echo y | PATH=$BIN:\$PATH bash $S/system.sh gc 14 >/dev/null; cat $BIN/calls.log"
check_out "gc with a bad number is refused" "usage" bash "$S/system.sh" gc many
check_out "rollback asks, then rolls back" "nixos-rebuild switch --rollback" bash -c "rm -f $BIN/calls.log; echo y | PATH=$BIN:\$PATH bash $S/system.sh rollback >/dev/null; cat $BIN/calls.log"
check_out "no = nothing happens" "cancelled" bash -c "echo n | PATH=$BIN:\$PATH bash $S/system.sh rollback"

echo "-- net ip"
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  info) [ "$2" = ghost ] && exit 1; exit 0 ;;
  config) echo "00:16:3e:aa:bb:cc" ;;
esac
FAKE
cat > "$BIN/unifi" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  reserved) [ "$2" = "00:16:3e:aa:bb:cc" ] && echo "10.10.95.25" ;;
  used) [ "$2" = "10.10.95.99" ] && echo "someone-else" ;;
  *) echo "unifi $*" ;;
esac
FAKE
chmod +x "$BIN/incus" "$BIN/unifi"
export HS_INCUS=$BIN/incus HS_UNIFI=$BIN/unifi
N="bash $S/net-ip.sh"
check_out "show" "10.10.95.25" $N web
check_out "set reserves for the MAC" "unifi set-ip 00:16:3e:aa:bb:cc 10.10.95.30 web" $N web set 10.10.95.30
check_out "an address in use is refused" "is in use" $N web set 10.10.95.99
check_out "a bad address is refused" "not an IPv4" $N web set nonsense
check_out "clear" "unifi clear-ip 00:16:3e:aa:bb:cc" $N web clear
check_out "an unknown instance is refused" "No instance called" $N ghost

echo "-- health"
cat > "$BIN/hc.sh" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = --test ]; then echo "test sent"; exit 0; fi
case "$HC_CASE" in
  ok) echo "No problems found." ;;
  bad) printf 'Backup is 4 days old\nThe encrypted storage is locked\nSomething odd\n\nNothing to send.\n' ;;
esac
FAKE
export HS_HEALTH_CHECK=$BIN/hc.sh
check_out "no problems" "Problems: None" env HC_CASE=ok bash "$S/health.sh"
out=$(HC_CASE=bad bash "$S/health.sh" 2>&1 || true)
check_out "a backup problem points to hs backup status" "Backup is 4 days old.*hs backup status" echo "$out"
check_out "a locked storage points to hs unlock" "locked.*hs unlock" echo "$out"
check_out "an unknown problem points to hs doctor" "Something odd.*hs doctor" echo "$out"
check_eq "problems give a non-zero exit" "1" "$(HC_CASE=bad bash "$S/health.sh" >/dev/null 2>&1; echo $?)"
check_out "test passes through" "test sent" bash "$S/health.sh" test
check_out "next: one line per problem with its fix" "Backup is 4 days old	hs backup status" env HC_CASE=bad bash "$S/health.sh" next
check_eq "next: no header" "3" "$(HC_CASE=bad bash "$S/health.sh" next | wc -l | tr -d ' ')"
check_eq "next: nothing when all is well" "" "$(HC_CASE=ok bash "$S/health.sh" next)"
check_eq "next: exit 0 even with problems" "0" "$(HC_CASE=bad bash "$S/health.sh" next >/dev/null 2>&1; echo $?)"
cat > "$BIN/hc2.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'bulk disk data-02 is MISSING. Replace it with: hs pool bulk replace\nshare docs is open to everyone. Set who may use it: hs share docs perm\nFailed job x\n\nNothing to send.\n'
FAKE
out=$(HS_HEALTH_CHECK=$BIN/hc2.sh bash "$S/health.sh" next)
check_out "a pool problem names the new pool command" "MISSING.*	hs pool bulk replace$" echo "$out"
check_out "a share problem names its own perm command" "open to everyone.*	hs share docs perm$" echo "$out"
check_out "a job problem names hs job list" "Failed job x	hs job list" echo "$out"
if grep -q "hs manage-pool\|hs manage-shares\|hs jobs" "$S/health-check.sh" "$S/health.sh" "$S/doctor.sh"; then fail "no old command names in health, health-check and doctor"; else pass "no old command names in health, health-check and doctor"; fi

echo "-- doctor without root, uptime without root"
printf 'adDomain = "ad.home.lan"\n' > "$WORK/ad.toml"
printf '#!/bin/sh\necho called > "%s/wbinfo.called"\nexit 1\n' "$WORK" > "$BIN/wbinfo"; chmod +x "$BIN/wbinfo"
out=$(HS_DOCTOR_UID=1000 HS_MACHINE_FILE=$WORK/ad.toml PATH=$BIN:$PATH bash "$S/doctor.sh" 2>&1 || true)
check_out "the domain trust is skipped, not broken" "cannot be checked without root" echo "$out"
if grep -q "trust to the domain is broken" <<<"$out"; then fail "no false alarm for the trust"; else pass "no false alarm for the trust"; fi
check_eq "wbinfo -t is not run" "no" "$(test -e "$WORK/wbinfo.called" && echo yes || echo no)"
echo "93784.5 1" > "$WORK/proc-uptime"
check_eq "uptime comes from /proc/uptime" "up 1 day, 2 hours, 3 minutes" "$(HS_PROC_UPTIME=$WORK/proc-uptime bash "$S/system.sh" info | sed -n 's/^ *Uptime *//p')"
check_eq "uptime of a missing file is a dash" "-" "$(HS_PROC_UPTIME=$WORK/none bash "$S/system.sh" info | sed -n 's/^ *Uptime *//p')"

echo "-- report"
R=$WORK/report.txt
bash "$S/report.sh" --out "$R" >/dev/null 2>&1
check "the report is written" test -s "$R"
check_out "with a system section" "===== system =====" cat "$R"
check_eq "and only the owner may read it" "600" "$(stat -c %a "$R")"

echo "-- migrate (stand-in for hs)"
cat > "$BIN/hsfake" <<'FAKE'
#!/usr/bin/env bash
echo "hs $*" >> "$LOGF"
FAKE
chmod +x "$BIN/hsfake"
export HS_BIN=$BIN/hsfake LOGF=$WORK/hs.log; : > "$LOGF"
Mg="bash $S/migrate.sh"
check_out "status lists the steps" "adopt" $Mg --status
$Mg --yes --disks ata-A,ata-B --parity ata-P >/dev/null 2>&1
check_out "adopt gets the disks" "hs pool bulk add --role adopt --disks ata-A,ata-B" cat "$LOGF"
check_out "parity gets its disk" "hs pool bulk add --role parity --disks ata-P" cat "$LOGF"
check_out "the first sync runs last" "hs pool bulk sync" cat "$LOGF"
check_eq "all steps are remembered" "6" "$(wc -l < "$HS_STATE_DIR/migrate.state")"
: > "$LOGF"; $Mg --yes >/dev/null 2>&1
check_eq "a second run does nothing" "0" "$(wc -c < "$LOGF" | tr -d ' ')"
$Mg --reset >/dev/null 2>&1
check_eq "reset forgets" "no" "$(test -f "$HS_STATE_DIR/migrate.state" && echo yes || echo no)"
check_out "adopt without disks stops with a hint" "Say which disks" $Mg --step adopt
check_out "an unknown step is refused" "usage" $Mg --step nonsense
: > "$LOGF"; $Mg --step shares >/dev/null 2>&1
check_out "one step only" "hs share repair" cat "$LOGF"

echo "-- first-run (stand-in for hs)"
: > "$LOGF"
bash "$S/first-run.sh" --language de --notify https://ntfy.sh/x >/dev/null 2>&1
check_out "the language is set" "hs config set language de" cat "$LOGF"
check_out "and the notification address" "hs config set notifyUrl https://ntfy.sh/x" cat "$LOGF"
check_out "the checklist names the commands" "hs backup init" bash "$S/first-run.sh" --yes

echo "-- old names are gone"
out=$(HS_CALLER=ui bash "$S/lib/hs.sh" jobs --running 2>&1 || true)
if grep -q "unknown command" <<<"$out"; then pass "an old name is an unknown command"; else fail "an old name is an unknown command: $out"; fi
if bash "$S/lib/hs.sh" help | grep -q '^  manage-ct'; then fail "help does not list old names"; else pass "help does not list old names"; fi

finish
