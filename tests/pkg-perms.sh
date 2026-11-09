#!/usr/bin/env bash
# Package permissions (ADR 0014, hobnix/server#239, step 1): `permissions` in package.toml is validated, shown by `hs pkg install|update` and
# `hs ext list`, and NEW permissions in an update need the typed package name (or --accept-permissions). Declared, not enforced. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have git || { skip "needs git"; finish; exit 0; }
have ssh-keygen || { skip "needs ssh-keygen"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1 HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
PKG="python3 -I $SCRIPTS/pkg.py"
tab=$'\t'

echo "-- validate"
T=$WORK/tree/capabilities/permext
mkdir -p "$T"
printf 'name = "permext"\nkind = "feature"\nrequires = []\nprovides = []\nneeds = []\nextension = true\ntitle = "Perm"\n%b\n' "${CAP:-}" > "$T/capability.toml"
manifest() {   # manifest <permissions line> [extra tables]
  printf 'name = "permext"\nversion = "1.0.0"\nkind = "extension"\ntitle = "Perm"\nrequires_core = ">=1"\naudience = "generic"\n%b\n' "$1" > "$T/package.toml"
}
validate() { HS_PACKAGES_ROOT=$WORK/tree $PKG validate 2>&1; }
good() { manifest "$2"; if validate >/dev/null; then pass "$1"; else fail "$1: $(validate)"; fi; }
bad() {   # bad <what> <word> <manifest text>
  manifest "$3"
  local out rc=0
  out=$(validate) || rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "$2"; then pass "$1"; else fail "$1 (rc $rc: $out)"; fi
}
good "no permissions key: still valid (not declared)" ''
good "an empty list is valid" 'permissions = []'
good "a full vocabulary line is valid" 'permissions = ["fs.write:/var/lib/hs/ext/permext", "net:lan", "host:incus", "secrets:api-key", "devices:gpu", "events.subscribe:pkg.*"]'
bad "an unknown key is refused" "unknown permission" 'permissions = ["root"]'
bad "net needs one of its words" "net" 'permissions = ["net:everywhere"]'
bad "a path must be absolute" "fs.write" 'permissions = ["fs.write:relative/x"]'
bad "a path may not leave" "fs.read" 'permissions = ["fs.read:/etc/../root"]'
bad "web.read takes no argument" "takes no argument" 'permissions = ["web.read:x"]'
bad "the same permission twice" "twice" 'permissions = ["host:incus", "host:incus"]'
bad "events.emit must lie below the package's kinds" "events.emit must lie below" 'permissions = ["events.emit:pkg.other.x"]'
EV='[[events]]\nkind = "done"\nlevel = "info"\nlabel = "Done"\nmeaning = "it ended"'
bad "[[events]] without events.emit is refused" "not events.emit" "permissions = [\"host:incus\"]\n$EV"
good "[[events]] covered by events.emit" "permissions = [\"events.emit:pkg.permext.*\"]\n$EV"
bad "an event outside the declared glob is refused" "not covered" "permissions = [\"events.emit:pkg.permext.other\"]\n$EV"
CAP='[[web.reads]]\nwords = "list"\nkind = "tsv"' 
printf 'name = "permext"\nkind = "feature"\nrequires = []\nprovides = []\nneeds = []\nextension = true\n%b\n' "$CAP" > "$T/capability.toml"
bad "[[web.reads]] without web.read is refused" "not web.read" 'permissions = ["host:incus"]'
good "[[web.reads]] with web.read" 'permissions = ["web.read"]'
manifest ''
check_out "perms says -  for a package without a declaration" "^-$" bash -c "HS_PACKAGES_ROOT=$WORK/tree $PKG perms permext"
manifest 'permissions = ["web.read", "host:incus"]'
check_eq "perms lists them one per line" "web.read,host:incus" "$(HS_PACKAGES_ROOT=$WORK/tree $PKG perms permext | paste -sd, -)"
check "perms of an unknown package fails" bash -c "! HS_PACKAGES_ROOT=$WORK/tree $PKG perms nonesuch 2>/dev/null"

echo "-- install and update from a repository"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/good" -C test >/dev/null
printf 'releaser@test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/good.pub")" > "$WORK/signers"
R=$WORK/repo; mkdir -p "$R/recipes/demo"; cd "$R"
git init -q . && git config user.email t@t && git config user.name t && git config gpg.format ssh && git config commit.gpgsign false
release() {   # release <tag> <version> <permissions line or empty>
  printf 'name = "demo"\nversion = "%s"\nkind = "recipe"\ntitle = "Demo"\nrequires_core = ">=1"\naudience = "generic"\nneeds = []\nuses = []\ninput = "none"\nscript = "run.sh"\n%b\n' "$2" "$3" > "$R/recipes/demo/package.toml"
  printf '#!/usr/bin/env bash\n# kind: generic\n# needs: -\n# uses: -\necho demo %s\n' "$2" > "$R/recipes/demo/run.sh"
  printf '[package.demo]\nversion = "%s"\nkind = "recipe"\npath = "recipes/demo"\nrequires_core = ">=1"\n' "$2" > "$R/index.toml"
  git add -A && git commit -q -m "demo $2" && git -c user.signingkey="$WORK/good.pub" tag -s "$1" -m "release $2"
}
release v1.0.0 1.0.0 ''
cd "$ROOT"
$PKG repo add test "$R" --key "$WORK/signers" >/dev/null
$PKG fetch test >/dev/null
check_out "install shows that nothing is declared and that it is not enforced" "not declared" bash -c "$PKG install demo 2>&1"
check_out "the installed copy says the same through perms" "^-$" bash -c "HS_PACKAGES_ROOT=$WORK/none $PKG perms demo"
cd "$R"; release v1.1.0 1.1.0 'permissions = ["host:incus"]'; cd "$ROOT"
$PKG fetch test >/dev/null
check_out "update shows the new permission" "NEW permissions.*host:incus" bash -c "$PKG update demo </dev/null 2>&1; true"
check_out "--yes alone without a terminal does not accept new permissions" "accept-permissions" bash -c "$PKG update demo --yes </dev/null 2>&1; true"
check "and nothing was installed" grep -q 'version = "1.0.0"' "$HS_STATE_DIR/packages/installed.toml"
check_out "--yes --accept-permissions installs" "demo 1[.]1[.]0 from test" bash -c "$PKG update demo --yes --accept-permissions </dev/null 2>&1"
cd "$R"; release v1.2.0 1.2.0 'permissions = ["host:incus"]'; cd "$ROOT"
$PKG fetch test >/dev/null
check_out "an update with the same permissions needs no acceptance" "demo 1[.]2[.]0 from test" bash -c "$PKG update demo --yes </dev/null 2>&1"
cd "$R"; release v1.3.0 1.3.0 'permissions = ["host:incus", "net:internet"]'; cd "$ROOT"
$PKG fetch test >/dev/null
check_out "only the added one is named" "NEW permissions.*net:internet$" bash -c "$PKG update demo </dev/null 2>&1; true"
check_out "a typed wrong name does not accept (terminal not available: refused)" "accept-permissions" bash -c "$PKG update demo --yes </dev/null 2>&1; true"
cd "$R"; release v1.4.0 1.4.0 'permissions = ["root"]'; cd "$ROOT"
$PKG fetch test >/dev/null
check_out "a release with an invalid permission is refused at install" "unknown permission" bash -c "$PKG update demo --yes --accept-permissions </dev/null 2>&1; true"
echo "-- enforcement: a package may not use more than it declared (ADR 0014 step 1b)"
E=$WORK/enf/permx; mkdir -p "$E"
printf 'name = "permx"\nkind = "feature"\nrequires = []\nprovides = []\nneeds = []\nextension = true\n[[web.reads]]\nwords = "list"\nkind = "tsv"\nttl = 30\n' > "$E/capability.toml"
printf 'sys\tsys ext permx list\tx.sh\treads\n' > "$E/commands.tsv"
pk() { printf 'name = "permx"\nversion = "1.0.0"\nkind = "extension"\ntitle = "X"\nrequires_core = ">=1"\naudience = "generic"\n%b\n' "$1" > "$E/package.toml"; }
webreads() {
  HS_PACKAGES_DIR=$WORK/enf HS_CAPABILITIES_FILE=$WORK/enf/caps HS_STATE_DIR=$WORK/enf/state python3 -I - "$SCRIPTS" <<'EOF2'
import sys
sys.path.insert(0, sys.argv[1])
import hs_ext
reads, _, _ = hs_ext.ext_load_web()
print("reads", len(reads))
EOF2
}
echo permx > "$WORK/enf/caps"
pk 'permissions = ["web.read"]'
check_eq "perms-check: covered declaration is fine" "" "$($PKG perms-check "$E" permx; true)"
check_eq "web reads load when covered" "1" "$(webreads | sed -n "s/^reads //p")"
pk ''
check_eq "no declaration: not checked, reads load (existing packages)" "1" "$(webreads | sed -n "s/^reads //p")"
pk 'permissions = ["host:incus"]'
check_out "perms-check names what is missing" "web.read" bash -c "$PKG perms-check '$E' permx; true"
check "perms-check exits 1" bash -c "! $PKG perms-check '$E' permx >/dev/null"
check_eq "web reads are NOT registered when the declaration does not cover them" "0" "$(webreads | sed -n "s/^reads //p")"
check_out "hs ext enable refuses it" "uses more than it declares" bash -c "HS_PACKAGES_DIR=$WORK/enf HS_CAPABILITIES_FILE=$WORK/enf/caps2 HS_STATE_DIR=$WORK/enf/state bash $SCRIPTS/ext.sh enable permx 2>&1; true"
pk 'permissions = ["host:incus", "web.read"]'
check_eq "fixing the declaration loads the reads again" "1" "$(webreads | sed -n "s/^reads //p")"
finish
