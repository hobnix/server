#!/usr/bin/env bash
# Events a package declares in package.toml [[events]] (hobnix/server#313): validation by pkg.py, the installed TSV, and its readers
# (state-db level, event-notify rules, the transition copy in scripts/lib/pkg-events). No root, python3 only.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v python3 >/dev/null || { echo "python3 missing: skipped"; exit 0; }
export HS_PLAIN=1 HS_LANG=en HS_CALLER=test HS_EVENT_NOROOT=1
mkdir -p "$WORK/state" "$WORK/pe" "$WORK/rules.d"
export HS_STATE_DIR=$WORK/state HS_PKG_EVENTS_DIR=$WORK/pe HS_STATE_DB=$WORK/state/state.db HS_NOTIFY_RULES_DIR=$WORK/rules.d
tab=$'\t'
PKG="python3 -I $SCRIPTS/pkg.py"
SD=$SCRIPTS/state-db.py
EN=$SCRIPTS/event-notify.py

echo "-- validate"
T=$WORK/tree/packages/evapp
mkdir -p "$T"
printf '#!/usr/bin/env bash\n# kind: generic\n# needs: -\n# uses: -\necho evapp\n' > "$T/run.sh"
manifest() {   # manifest <events text>
  printf 'name = "evapp"\nversion = "1.0.0"\nkind = "recipe"\ntitle = "Evapp"\nrequires_core = ">=1"\naudience = "generic"\nneeds = []\nuses = []\ninput = "none"\nscript = "run.sh"\n%b\n' "$1" > "$T/package.toml"
}
GOOD='[[events]]\nkind = "boom"\nlevel = "error"\nlabel = "Boom"\nmeaning = "it broke"\npayload = ["name", "sub?"]\nnotify = { category = "alarm", priority = "urgent", title = "{name}: {label}", message = "{text}" }\n[[events]]\nkind = "quiet"\nlevel = "info"\nlabel = "Quiet"\nmeaning = "nothing special"'
validate() { HS_PACKAGES_ROOT=$WORK/tree python3 -I "$SCRIPTS/pkg.py" validate 2>&1; }
manifest "$GOOD"
check "a manifest with two events validates" bash -c "HS_PACKAGES_ROOT=$WORK/tree python3 -I $SCRIPTS/pkg.py validate"
bad() {   # bad <what> <word> <events text>
  manifest "$3"
  local out rc=0
  out=$(validate) || rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "$2"; then pass "$1"; else fail "$1 (rc $rc: $out)"; fi
}
bad "a bad level is a problem" "level" '[[events]]\nkind = "boom"\nlevel = "loud"\nlabel = "B"\nmeaning = "m"'
bad "a kind with the prefix is a problem" "part after" '[[events]]\nkind = "pkg.evapp.x"\nlevel = "info"\nlabel = "B"\nmeaning = "m"'
bad "a kind twice is a problem" "twice" '[[events]]\nkind = "x"\nlevel = "info"\nlabel = "B"\nmeaning = "m"\n[[events]]\nkind = "x"\nlevel = "info"\nlabel = "B"\nmeaning = "m"'
bad "a bad notify category is a problem" "category" '[[events]]\nkind = "x"\nlevel = "info"\nlabel = "B"\nmeaning = "m"\nnotify = { category = "bogus", title = "t", message = "m" }'
bad "notify without a message is a problem" "title and a message" '[[events]]\nkind = "x"\nlevel = "info"\nlabel = "B"\nmeaning = "m"\nnotify = { category = "ok", title = "t" }'
bad "an unknown event key is a problem" "unknown key" '[[events]]\nkind = "x"\nlevel = "info"\nlabel = "B"\nmeaning = "m"\ncolour = "red"'
bad "a string payload is a problem" "payload is a list" '[[events]]\nkind = "x"\nlevel = "info"\nlabel = "B"\nmeaning = "m"\npayload = "service"'
bad "a bad payload key is a problem" "payload key" '[[events]]\nkind = "x"\nlevel = "info"\nlabel = "B"\nmeaning = "m"\npayload = ["Bad"]'

echo "-- the readers"
python3 -I -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("pkg_events", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.write("evapp", [
  {"kind": "boom", "level": "error", "label": "Boom", "meaning": "it broke", "payload": ["name"],
   "notify": {"category": "alarm", "priority": "urgent", "title": "{name}: {label}", "message": "{text}"}},
  {"kind": "quiet", "level": "info", "label": "Quiet", "meaning": "nothing special"}])
' "$SCRIPTS/lib/pkg_events.py"
check "the installed file exists" test -f "$WORK/pe/evapp.tsv"
printf 'pkg.other.x\terror\t-\tX\t-\tstolen\t-\t-\t-\t-\n' >> "$WORK/pe/evapp.tsv"
level() { python3 "$SD" emit "$1" x >/dev/null; python3 "$SD" event-list 1 | cut -f6 | head -n1; }
check_eq "a declared error level is used" "error" "$(level pkg.evapp.boom)"
check_eq "a declared info level is used" "info" "$(level pkg.evapp.quiet)"
check_eq "a row of another package in the file is ignored" "info" "$(level pkg.other.x)"
check_out "the declared rule matches" "alarm${tab}urgent" python3 "$EN" match pkg.evapp.boom
if python3 "$EN" match pkg.evapp.quiet >/dev/null 2>&1; then fail "an event without notify has no rule"; else pass "an event without notify has no rule"; fi
printf 'pkg.evapp.boom\t-\t-\t-\t-\n' > "$WORK/rules.d/10.tsv"
check_out "a drop-in wins over the package" "^pkg.evapp.boom${tab}-${tab}" python3 "$EN" match pkg.evapp.boom
rm -f "$WORK/rules.d/10.tsv" "$WORK/pe/evapp.tsv"

echo "-- the transition copy"
check_eq "the copy gives the level" "warn" "$(level pkg.sabnzbd.failed)"
printf 'pkg.sabnzbd.failed\tinfo\t-\tF\t-\tm\t-\t-\t-\t-\n' > "$WORK/pe/sabnzbd.tsv"
check_eq "an installed file replaces the copy" "info" "$(level pkg.sabnzbd.failed)"
if python3 "$EN" match pkg.sabnzbd.finished >/dev/null 2>&1; then fail "no fallback to the copy per kind"; else pass "no fallback to the copy per kind"; fi
rm -f "$WORK/pe/sabnzbd.tsv"

echo "-- the copy is well formed"
n=$(cat "$SCRIPTS"/lib/pkg-events/*.tsv | grep -cv '^#\|^$')
m=$(python3 -I -c '
import importlib.util, sys, glob, os
s = importlib.util.spec_from_file_location("pkg_events", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(sum(len(m.read_file(p, os.path.basename(p)[:-4])) for p in glob.glob(os.path.join(m.CORE_DIR, "*.tsv"))))
' "$SCRIPTS/lib/pkg_events.py")
check_eq "every row of the copy is accepted" "$n" "$m"
finish
