#!/usr/bin/env bash
# hs update --preview against a throwaway Git upstream and stand-ins for nixos-rebuild / nix-build.
# No root, no network. It must change nothing but the fetched refs.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false"
UP=$WORK/up.git; REPO=$WORK/repo; PUSHER=$WORK/pusher
BIN=$WORK/bin; mkdir -p "$BIN"
export HS_REPO=$REPO HS_MACHINE_FILE=$WORK/machine.toml HS_STATE_DIR=$WORK/state
P="bash $SCRIPTS/update-preview.sh"

git init -q --bare "$UP"
git clone -q "$UP" "$PUSHER" 2>/dev/null
printf '# name\nhostName = "a"\n\n# keys\nsshKeys = []\n' > "$PUSHER/machine.toml.example"
printf '{ }\n' > "$PUSHER/configuration.nix"
( cd "$PUSHER" && $G add -A && $G commit -q -m "first" && git push -q origin HEAD 2>/dev/null )
git clone -q "$UP" "$REPO" 2>/dev/null
cp "$REPO/machine.toml.example" "$HS_MACHINE_FILE"

# stand-ins
cat > "$BIN/nixos-rebuild" <<'FAKE'
#!/usr/bin/env bash
echo "building the system configuration..."
echo "would restart the following units: sshd.service"
echo "would start the following units: hs-new.service"
echo "args: $*" >> "${HS_FAKE_LOG:-/dev/null}"
FAKE
cat > "$BIN/nix-build" <<'FAKE'
#!/usr/bin/env bash
echo "these 3 derivations will be built:"
echo "  /nix/store/aaa-hs.drv"
echo "these 40 paths will be fetched (12.5 MiB download, 80 MiB unpacked):"
FAKE
chmod +x "$BIN/nixos-rebuild" "$BIN/nix-build"
export PATH="$BIN:$PATH" HS_FAKE_LOG=$WORK/fake.log

echo "-- nothing new"
check_out "already current" "Already the latest configuration" $P --no-build
check_out "no new options" "Nothing new: machine.toml has every option" $P --no-build
check_out "--no-build says it skipped" "build preview was skipped" $P --no-build

echo "-- something new upstream"
printf '# name\nhostName = "a"\n\n# keys\nsshKeys = []\n\n# brandNewOption does a thing\n# brandNewOption = true\n' > "$PUSHER/machine.toml.example"
echo '{ x = 1; }' > "$PUSHER/configuration.nix"
( cd "$PUSHER" && $G add -A && $G commit -q -m "add brandNewOption" && git push -q origin HEAD 2>/dev/null )
head_before=$(git -C "$REPO" rev-parse HEAD)
sum_before=$(cksum < "$HS_MACHINE_FILE")
check_out "the commit is listed" "1 new change\(s\) from .*:" $P --no-build
check_out "with its subject" "add brandNewOption" $P --no-build
check_out "and the diffstat" "machine.toml.example +\|" $P --no-build
check_out "the new option is announced" "brandNewOption" $P --no-build
check_eq "nothing was pulled" "$head_before" "$(git -C "$REPO" rev-parse HEAD)"
check_eq "machine.toml is untouched" "$sum_before" "$(cksum < "$HS_MACHINE_FILE")"
check_eq "the working tree is untouched" "{ }" "$(cat "$REPO/configuration.nix")"

echo "-- the build part"
check_out "not root: nix-build summary" "3 derivations will be built" $P
check_out "and what is downloaded" "40 paths will be fetched" $P
check_out "root: the units that would restart" "would restart the following units: sshd.service" env HS_PREVIEW_AS_ROOT=1 $P
check_out "root: the units that would start" "would start the following units: hs-new.service" env HS_PREVIEW_AS_ROOT=1 $P
rm -f "$HS_FAKE_LOG"
env HS_PREVIEW_AS_ROOT=1 $P >/dev/null 2>&1 || true
check_out "the upstream copy is built, not the checkout" "nixos-config=.*/cfg/configuration.nix" cat "$HS_FAKE_LOG"
check_out "ends with the hint" "Nothing was applied" $P
cat > "$BIN/nixos-rebuild" <<'FAKE'
#!/usr/bin/env bash
echo "error: attribute 'foo' missing" >&2
exit 1
FAKE
check_out "a configuration that does not build is a warning" "does not build" env HS_PREVIEW_AS_ROOT=1 $P
check_eq "and fails" "1" "$(env HS_PREVIEW_AS_ROOT=1 $P >/dev/null 2>&1; echo $?)"

echo "-- many new changes (more than the lines shown): the update must not die on SIGPIPE"
( cd "$PUSHER" && for i in $(seq 1 40); do echo "line $i" >> many.txt; $G add many.txt; $G commit -q -m "change $i"; done && git push -q origin HEAD 2>/dev/null )
check_eq "preview with 40+ new changes exits 0" "0" "$($P --no-build >/dev/null 2>&1; echo $?)"
check_out "and says how many are not listed" "\.\.\. and [0-9]+ more" $P --no-build
check "no update script pipes git log into head (SIGPIPE + pipefail ended hs update after the Update step)" bash -c "! grep -nE 'log .*[|] *head' $SCRIPTS/update.sh $SCRIPTS/update-preview.sh"

echo "-- local state"
( cd "$REPO" && echo '{ y = 2; }' > configuration.nix )
check_out "local changes in a file that changes upstream" "Local changes in files that change upstream" $P --no-build
( cd "$REPO" && git checkout -q configuration.nix && echo extra > extra.txt && $G add extra.txt && $G commit -q -m local )
check_out "a local commit" "1 commit\(s\) that are not upstream" $P --no-build

echo "-- usage and through hs"
check_out "a wrong option" "usage: hs update --preview" $P --nope
check_out "hs update --preview" "Preview of the update" bash "$SCRIPTS/lib/hs.sh" update --preview --no-build
check_out "hs help update" "update --preview" bash "$SCRIPTS/lib/hs.sh" help update

finish
