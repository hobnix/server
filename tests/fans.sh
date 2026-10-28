#!/usr/bin/env bash
# hs fans clean (scripts/fans.sh) against a fake hwmon directory. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
H=$WORK/hwmon; mkdir -p "$H/hwmon0" "$H/hwmon5"
export HS_HWMON_DIR=$H
echo coretemp > "$H/hwmon0/name"; echo 45000 > "$H/hwmon0/temp1_input"
echo nct6793 > "$H/hwmon5/name"
echo 5 > "$H/hwmon5/pwm1_enable"; echo 45 > "$H/hwmon5/pwm1"; echo 200 > "$H/hwmon5/fan1_input"
echo 1 > "$H/hwmon5/pwm2_enable"; echo 120 > "$H/hwmon5/pwm2"; echo 0 > "$H/hwmon5/fan2_input"
# the stand-in for sleep shows what the fans were set to while they ran
cat > "$WORK/nap" <<NAP
#!/usr/bin/env bash
echo "\$(cat $H/hwmon5/pwm1_enable) \$(cat $H/hwmon5/pwm1) \$(cat $H/hwmon5/pwm2_enable) \$(cat $H/hwmon5/pwm2) for \$1" > $WORK/during
NAP
chmod +x "$WORK/nap"
export HS_FANS_SLEEP="bash $WORK/nap"
F="bash $SCRIPTS/fans.sh"

check_out "clean runs and says it is done" "back as they were" $F clean 5
check_eq "fans were at 100 % in manual mode meanwhile, for 5 s" "1 255 1 255 for 5" "$(cat "$WORK/during")"
check_eq "channel 1 is back in its mode" "5" "$(cat "$H/hwmon5/pwm1_enable")"
check_eq "channel 2 is back in manual with its value" "1 120" "$(cat "$H/hwmon5/pwm2_enable") $(cat "$H/hwmon5/pwm2")"
check_out "a fan that runs is listed" "200 rpm" $F clean 3
check_out "default is 8 seconds" "for 8" bash -c "$F clean >/dev/null; cat $WORK/during"
check_eq "too short is refused" "1" "$($F clean 1 >/dev/null 2>&1; echo $?)"
check_eq "too long is refused" "1" "$($F clean 99 >/dev/null 2>&1; echo $?)"
check_eq "not a number is refused" "1" "$($F clean abc >/dev/null 2>&1; echo $?)"

# a failing step in between still puts everything back
cat > "$WORK/nap2" <<'NAP'
#!/usr/bin/env bash
exit 7
NAP
HS_FANS_SLEEP="bash $WORK/nap2" $F clean 4 >/dev/null 2>&1 || true
echo 1 > "$H/hwmon5/pwm2_enable"; echo 120 > "$H/hwmon5/pwm2"
check_eq "settings are restored when the wait dies" "5 1 120" "$(cat "$H/hwmon5/pwm1_enable") $(cat "$H/hwmon5/pwm2_enable") $(cat "$H/hwmon5/pwm2")"

echo 80000 > "$H/hwmon0/temp1_input"
check_out "a hot CPU stops it" "not running the fans" $F clean 5
check_eq "and nothing was touched" "5" "$(cat "$H/hwmon5/pwm1_enable")"
echo 45000 > "$H/hwmon0/temp1_input"

rm -rf "$H/hwmon5"
check_out "no fan controller is said plainly" "no fan controller" $F clean 5
finish
