#!/usr/bin/env bash
# The Hobnix version (issue #400): scripts/lib/version.sh, the "Hobnix" line of hs system info and the version row of hs sys status.
# Real git in temp dirs, nothing is fetched. No root.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state
mkdir -p "$HS_STATE_DIR"
G="git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false"
R=$WORK/repo; export HS_REPO=$R
. "$SCRIPTS/lib/version.sh"

echo "-- git describe"
git init -q "$R"; echo 0 > "$R/f"; ( cd "$R" && $G add f && $G commit -q -m zero )
short=$(git -C "$R" rev-parse --short HEAD)
check_eq "before the first tag: the short hash" "$short" "$(hobnix_version)"
( cd "$R" && $G tag v0.1.0 )
check_eq "on the tag: the tag" "v0.1.0" "$(hobnix_version)"
( cd "$R" && echo 1 > f && $G commit -q -am one )
check_out "after the tag: tag, count and hash" '^v0\.1\.0-1-g[0-9a-f]+$' hobnix_version

echo "-- no checkout"
N=$WORK/plain; mkdir -p "$N"
check_eq "nothing known: a dash" "-" "$(hobnix_version "$N")"
printf 'v0.1.0\n' > "$N/.hobnix-version"
check_eq "the version the installer kept" "v0.1.0" "$(hobnix_version "$N")"
printf 'not a version; rm -rf\n' > "$N/.hobnix-version"
check_eq "an odd file is not shown" "-" "$(hobnix_version "$N")"

echo "-- hs system info and hs sys status"
check_out "info has the line Hobnix with the version" "Hobnix +v0\.1\.0-1-g" bash "$SCRIPTS/system.sh" info
export HS_REPO=$N
check_out "info without a checkout shows a dash" "Hobnix +-" bash "$SCRIPTS/system.sh" info
export HS_REPO=$R
for b in unlock jobs cache smart monitor incus; do printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/$b"; chmod +x "$WORK/$b"; done
out=$(HS_UNLOCK=$WORK/unlock HS_JOBS=$WORK/jobs HS_SHARE_CACHE=$WORK/cache HS_DISK_HEALTH=$WORK/smart HS_MONITOR=$WORK/monitor HS_INCUS=$WORK/incus bash "$SCRIPTS/overview-status.sh")
check_out "sys status ends with the version row" '^version	v0\.1\.0-1-g' bash -c 'echo "$1" | tail -n 1' _ "$out"
check "the web shows it on the Overview" grep -q "m.version" "$ROOT/web/src/pages/Summary.svelte"
check "iso.nix puts the version in the file name and /etc/hs-installer-version" bash -c 'grep -q "image.baseName = .*\"homeserver-installer-\${describe}\"" "$1/installer/iso.nix" && grep -q "hs-installer-version" "$1/installer/iso.nix"' _ "$ROOT"
finish
