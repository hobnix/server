#!/usr/bin/env bash
# hs shutdown / hs reboot: the command that would run, the refusals, the busy check. Fake systemctl and bootctl, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_LOCK=$WORK/lock HS_LOCK_ADMIN=$WORK/admin HS_EFI_DIR=$WORK/efi
P="bash $SCRIPTS/power.sh"
LOG=$WORK/calls; : > "$LOG"
cat > "$WORK/systemctl" <<EOS
#!/usr/bin/env bash
case "\$1" in
  list-units) [ -n "\${FAKE_JOB:-}" ] && echo "\$FAKE_JOB loaded active running x" ;;
  is-active) [ "\${FAKE_ACTIVE:-}" = "\$2" ] && echo active || echo inactive ;;
  *) echo "\$*" >> "$LOG" ;;
esac
EOS
cat > "$WORK/bootctl" <<'EOS'
#!/usr/bin/env bash
printf '        id: nixos-generation-9.conf\n        id: auto-windows\n'
EOS
chmod +x "$WORK/systemctl" "$WORK/bootctl"
export HS_SYSTEMCTL=$WORK/systemctl HS_BOOTCTL=$WORK/bootctl
calls() { cat "$LOG"; }

echo "-- the commands"
check_out "shutdown" "poweroff" $P shutdown --dry-run
check_out "reboot" "systemctl reboot|systemctl$" $P reboot --dry-run
check_out "menu" " --boot-loader-menu=60" $P reboot --menu --dry-run
mkdir -p "$HS_EFI_DIR"
check_out "firmware" " --firmware-setup" $P reboot --firmware --dry-run
check_out "entry" " --boot-loader-entry=auto-windows" $P reboot --entry auto-windows --dry-run
check_out "an unknown entry" "No boot entry nope" $P reboot --entry nope --dry-run
rmdir "$HS_EFI_DIR"
check_out "firmware without EFI" "not start in EFI mode" $P reboot --firmware --dry-run
check_out "two modes" "Choose one" $P reboot --menu --firmware --dry-run
check_out "menu with shutdown" "only works with hs reboot" $P shutdown --menu
check_out "entry without id" "needs an entry id" $P reboot --entry

echo "-- asking"
check_out "no terminal, no --yes" "without --yes" $P reboot
check_out "nothing ran" "^$" calls
$P shutdown --yes >/dev/null 2>&1 || true
check_out "--yes runs it" "poweroff" calls
: > "$LOG"
printf 'n\n' | HS_GUIDED_TTY=1 HS_CALLER= $P reboot >/dev/null 2>&1 || true
check_out "a no does nothing" "^$" calls
printf 'y\n' | HS_GUIDED_TTY=1 HS_CALLER= $P reboot >/dev/null 2>&1 || true
check_out "a yes reboots" "reboot" calls

echo "-- busy"
: > "$LOG"
check_out "a job running" "hs-job-pool-bulk.service" env FAKE_JOB=hs-job-pool-bulk.service $P reboot --yes
check_out "a backup running" "hs-backup.service is running" env FAKE_ACTIVE=hs-backup.service $P reboot --yes
check_out "the answer says how to go on" " --force" env FAKE_ACTIVE=hs-backup.service $P reboot --yes
check_out "nothing ran" "^$" calls
: > "$HS_LOCK_ADMIN"
check_out "a pool change" "pool change" $P shutdown --yes
check_out "still nothing ran" "^$" calls
rm -f "$HS_LOCK_ADMIN"
if have flock; then
( exec 9>"$HS_LOCK"; flock -n 9; sleep 3 ) &
sleep 1
check_out "the bulk lock" "bulk lock" $P shutdown --yes
fi
check_out "--force goes ahead" "poweroff" env FAKE_ACTIVE=hs-backup.service $P shutdown --yes --force
wait 2>/dev/null || true
finish
