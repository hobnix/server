#!/usr/bin/env bash
# The nixpkgs pin (config/nixpkgs-pin.toml, scripts/dev/nixpkgs-pin.sh): reading, the malformed file, bump to a given revision, and that the
# real file is well formed and written in one place only. No root, no network (bump --rev needs none).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
P="bash $SCRIPTS/dev/nixpkgs-pin.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
printf '# comment\nchannel = "nixos-26.05"\nrev = "%s"\n' "$A" > "$T/pin.toml"
export HS_NIXPKGS_PIN_FILE=$T/pin.toml

check_eq "get channel" "nixos-26.05" "$($P get channel)"
check_eq "get rev" "$A" "$($P get rev)"
check_eq "get url" "https://github.com/NixOS/nixpkgs/archive/$A.tar.gz" "$($P get url)"
check_eq "github-env" "NIXPKGS_REV=$A NIXPKGS_CHANNEL=nixos-26.05" "$($P github-env | paste -sd' ')"
check_eq "bump to a given revision prints old and new" "$A $B" "$($P bump --rev $B)"
check_eq "the file holds the new revision, the comment stays" "$B 1" "$($P get rev) $(grep -c '^# comment' "$T/pin.toml")"
check_eq "bump to the same revision changes nothing" "unchanged" "$($P bump --rev $B)"
if $P bump --rev nothex >/dev/null 2>&1; then fail "a malformed revision was accepted"; else pass "a malformed revision is refused"; fi
printf 'channel = "stable"\nrev = "%s"\n' "$A" > "$T/pin.toml"
if $P get rev >/dev/null 2>&1; then fail "a malformed channel was accepted"; else pass "a malformed channel is refused"; fi
printf 'channel = "nixos-26.05"\n' > "$T/pin.toml"
if $P get rev >/dev/null 2>&1; then fail "a missing revision was accepted"; else pass "a missing revision is refused"; fi
unset HS_NIXPKGS_PIN_FILE
check "the real pin file is well formed and written in one place only" $P check
finish
