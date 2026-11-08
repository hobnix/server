#!/usr/bin/env bash
# Every path that applies a configuration change says WHEN it takes effect before the person applies it (docs/adr/0002 rule 4): one of the two fixed
# sentences ("takes effect at once" / "takes effect with hs rebuild"), a rebuild sentence with the last measured time (or "several minutes" before
# one was measured). Covers the plans of `hs sys ... plan` (the web), the CLI commands that write machine.toml or the settings, and the web dialogs.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test
unset HS_GUIDED_TTY
T=$'\t'
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_ETC_DIR=$WORK/etc HS_MACHINE_EXAMPLE=$ROOT/machine.toml.example HS_MACHINE_FILE=$WORK/machine.toml
export HS_CAPABILITIES_FILE=$WORK/caps HS_CAPABILITIES_TSV=/dev/null HS_PACKAGES_DIR=$WORK/packages
mkdir -p "$HS_STATE_DIR" "$HS_SETTINGS_DIR" "$HS_ETC_DIR" "$HS_PACKAGES_DIR"/{metrics,games}
printf 'name = "metrics"\ntitle = "Metrics"\nnix = "module.nix"\n' > "$HS_PACKAGES_DIR/metrics/capability.toml"; : > "$HS_PACKAGES_DIR/metrics/module.nix"
printf 'name = "games"\ntitle = "Game PCs"\nextension = true\n' > "$HS_PACKAGES_DIR/games/capability.toml"
printf 'user\text games list\tx.sh\tlist\tlist\t-\t-\n' > "$HS_PACKAGES_DIR/games/commands.tsv"
printf 'metrics\n' > "$HS_CAPABILITIES_FILE"
cp "$ROOT/machine.toml.example" "$HS_MACHINE_FILE"
printf 'hostName = "hs"\ncapabilities = ["metrics"]\n' > "$WORK/parts.toml"

NOW='takes effect at once'
RB='takes effect with hs rebuild'
# plan <script> <args...>: the plan lines of a script into $out
plan() { local s=$1; shift; out=$(timeout 60 bash "$SCRIPTS/$s" "$@" </dev/null 2>/dev/null) || true; }
says() { grep -q "^note${T}.*$2" <<<"$out" && pass "$1" || fail "$1: $out"; }

echo "-- plans of hs sys ... plan: the sentence is a note, before the command line"
rm -f "$HS_STATE_DIR/last-rebuild-seconds"
plan config-change.sh plan set syncEveryHours 6;            says "config plan, machine option: rebuild sentence" "$RB"
plan config-change.sh plan set language de;                 says "config plan, runtime setting: at once sentence" "$NOW"
plan config-change.sh plan apply --set syncEveryHours=6;    says "config apply plan (wizard), machine option" "$RB"
plan config-change.sh plan apply --set language=de;         says "config apply plan (wizard), runtime setting" "$NOW"
cp "$WORK/parts.toml" "$HS_MACHINE_FILE"
plan part-change.sh plan enable games;                      says "parts plan: extension without a module is at once" "$NOW"
plan part-change.sh plan disable metrics;                   says "parts plan: a module needs a rebuild" "$RB"
ssh-keygen -q -t ed25519 -N '' -C t@pc -f "$WORK/k" >/dev/null 2>&1 && {
  plan ssh-key-change.sh plan add "$(cat "$WORK/k.pub")";   says "ssh key plan" "$RB"; } || skip "ssh-keygen missing: ssh key plan"
plan system-change.sh plan rebuild;                         says "system rebuild plan names the time" "This job runs the rebuild\. A rebuild takes several minutes"
rm -f "$HS_STATE_DIR/last-rebuild-seconds"; plan config-change.sh plan set syncEveryHours 6
grep -q "^note${T}.*several minutes" <<<"$out" && pass "no measured rebuild yet: the placeholder says several minutes" || fail "placeholder: $out"
grep -q 'took about' <<<"$out" && fail "a time that was never measured is named: $out" || pass "no measured rebuild yet: no invented time"
printf '125\n' > "$HS_STATE_DIR/last-rebuild-seconds"; plan config-change.sh plan set syncEveryHours 6
says "a measured rebuild: the last time is named (125 s = 3 min)" 'The last rebuild took about 3 min\.'
printf 'x\n' > "$HS_STATE_DIR/last-rebuild-seconds"; plan config-change.sh plan set syncEveryHours 6
says "garbage in the time file falls back to the placeholder" 'several minutes'
rm -f "$HS_STATE_DIR/last-rebuild-seconds"

echo "-- CLI commands say it before they write"
cp "$ROOT/machine.toml.example" "$HS_MACHINE_FILE"
cli=$(bash "$SCRIPTS/config.sh" set syncEveryHours 6 --dry-run 2>&1 || true)
grep -q "$RB" <<<"$cli" && pass "hs config set (machine.toml) names the rebuild before the write (dry run)" || fail "config set: $cli"
cli=$(bash "$SCRIPTS/config.sh" set language de --dry-run 2>&1 || true)
grep -q "$NOW" <<<"$cli" && pass "hs config set (runtime) says at once (dry run)" || fail "config set runtime: $cli"
cli=$(bash "$SCRIPTS/config.sh" set syncEveryHours 6 2>&1 || true)
n1=$(grep -n "$RB" <<<"$cli" | head -n 1 | cut -d: -f1); n2=$(grep -n 'is set' <<<"$cli" | head -n 1 | cut -d: -f1)
[ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" -lt "$n2" ] && pass "the sentence comes before 'is set'" || fail "order: $cli"

echo "-- no path forgets it: every script that writes machine.toml or the settings uses lib/effect.sh or is listed with a reason"
# Not config paths that ask: the helpers themselves, the installer (writes the file of a server that does not run yet), the files the notify and
# UniFi commands keep in /var/lib/hs (credentials and channels, saved and used at once, no plan), and ssh-key-change.sh / docker-setup.sh which
# only call the scripts below.
exempt=" lib/machine.sh lib/setting.sh install-wizard.sh notify-channel.sh unifi.sh "
missing=""
for f in $(cd "$SCRIPTS" && grep -rlE 'machine_set|machine_unset|setting_set|setting_unset' --include=*.sh . | sed 's|^\./||' | sort); do
  case "$exempt" in *" $f "*) continue ;; esac
  grep -q 'lib/effect.sh' "$SCRIPTS/$f" || missing="$missing $f"
done
check_eq "every config-writing script sources lib/effect.sh (missing:$missing)" "" "$missing"
for f in ssh-key-change.sh docker-setup.sh system-change.sh gateway-setup.sh; do
  check "$f sources lib/effect.sh" grep -q 'lib/effect.sh' "$SCRIPTS/$f"
done

echo "-- the web dialogs show it"
if command -v node >/dev/null 2>&1; then
  node "$ROOT/tests/apply-effect.mjs" && pass "web effect helper and dialogs" || fail "web effect tests"
else skip "node is not installed: web effect tests"; fi
finish
