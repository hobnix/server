#!/usr/bin/env bash
# scripts/logs.sh (hs sys logs units|show): the journal filtered by unit, level and time. A fake journalctl records its arguments: no systemd, no root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en
unset HS_CALLER
cat > "$WORK/journalctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$(dirname "$0")/args"
printf -- '-- Boot abcdef --\n2026-10-08T05:00:00+0000 host sshd[1]: Accepted key\n2026-10-08T05:00:01+0000 host kernel: error on sdz\n'
FAKE
chmod +x "$WORK/journalctl"
export HS_JOURNALCTL=$WORK/journalctl
L() { bash "$SCRIPTS/logs.sh" "$@"; }
args() { cat "$WORK/args"; }

echo "-- units"
out=$(L units)
check_eq "seven choices, key and label" "7" "$(wc -l <<<"$out" | tr -d ' ')"
check_out "all comes first" "^all	Everything" echo "$out"
check_out "the hs jobs" "^jobs	The hs jobs" echo "$out"

echo "-- show"
out=$(L show)
check_eq "the defaults: today, everything, 300 lines" "--since today -n 300 --no-pager -o short-iso" "$(args)"
check_out "the journal lines come through" "Accepted key" echo "$out"
if grep -q '^-- ' <<<"$out"; then fail "the '-- Boot' marker lines are dropped"; else pass "the '-- Boot' marker lines are dropped"; fi
L show --unit jobs --level err --since 1h --lines 50 >/dev/null
check_eq "unit, level, time and count become journalctl arguments" "-u hs-* -p err --since 1 hour ago -n 50 --no-pager -o short-iso" "$(args)"
L show --unit kernel --level warning --since boot >/dev/null
check_eq "the kernel, warnings, since the boot" "-k -p warning -b -n 300 --no-pager -o short-iso" "$(args)"
L show --unit zfs >/dev/null
check_eq "zfs is two units" "-u zfs-* -u zfs-zed --since today -n 300 --no-pager -o short-iso" "$(args)"
L show --lines 99999 >/dev/null
check_eq "at most 2000 lines" "--since today -n 2000 --no-pager -o short-iso" "$(args)"
check_eq "an unknown unit is refused" "1" "$(L show --unit sshd >/dev/null 2>&1; echo $?)"
check_eq "an unknown level is refused" "1" "$(L show --level debug >/dev/null 2>&1; echo $?)"
check_eq "an unknown time is refused" "1" "$(L show --since yesterday >/dev/null 2>&1; echo $?)"
check_eq "a count that is not a number is refused" "1" "$(L show --lines many >/dev/null 2>&1; echo $?)"
check_eq "an unknown option is refused" "1" "$(L show --bogus >/dev/null 2>&1; echo $?)"
check_eq "no argument is a usage error" "1" "$(L >/dev/null 2>&1; echo $?)"

echo "-- through the registry (hs sys logs ...)"
fake=$WORK/reg; mkdir -p "$fake/lib"
cp "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/job.sh "$fake/lib/"; cp -r "$SCRIPTS"/lib/i18n "$fake/lib/"
cp "$SCRIPTS/lib/registry.tsv" "$fake/lib/"; cp "$SCRIPTS/logs.sh" "$fake/"
F="env HS_CALLER=t HS_COMPLETE_DIR=$WORK/complete bash $fake/lib/hs.sh"
check_eq "hs sys logs units" "$(L units)" "$($F sys logs units)"
$F sys logs show --unit incus --level warning >/dev/null
check_eq "hs sys logs show passes its options on" "-u incus -u incus-* -p warning --since today -n 300 --no-pager -o short-iso" "$(args)"

finish
