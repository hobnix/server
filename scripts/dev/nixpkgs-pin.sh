#!/usr/bin/env bash
# The nixpkgs pin (config/nixpkgs-pin.toml): read it, check it, move it. Developer tool and CI helper, not an `hs` command.
#
#   nixpkgs-pin.sh get channel|rev|url     print one value (url: the tarball of the pinned revision)
#   nixpkgs-pin.sh github-env              KEY=value lines for $GITHUB_ENV: NIXPKGS_REV, NIXPKGS_CHANNEL
#   nixpkgs-pin.sh check                   the file is well formed and no other file hard-codes the revision (exit 1 otherwise)
#   nixpkgs-pin.sh bump [--rev <sha>]      move `rev` to the head of `channel` (or to <sha>); prints "old new" or "unchanged"; needs network
#   nixpkgs-pin.sh latest                  the head of `channel` (git ls-remote), nothing written
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
pin=${HS_NIXPKGS_PIN_FILE:-$repo/config/nixpkgs-pin.toml}
val() { sed -n "s/^$1 *= *\"\\([^\"]*\\)\" *\$/\\1/p" "$pin" | head -n1; }
channel=$(val channel); rev=$(val rev)
valid() { [[ "$channel" =~ ^nixos-[0-9]{2}\.[0-9]{2}$|^nixos-unstable$ ]] && [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; }
latest() { git ls-remote https://github.com/NixOS/nixpkgs "refs/heads/$channel" | cut -f1; }
case "${1:-}" in
  get)
    valid || { echo "config/nixpkgs-pin.toml: channel or rev is missing or malformed" >&2; exit 1; }
    case "${2:-}" in
      channel) echo "$channel" ;; rev) echo "$rev" ;;
      url) echo "https://github.com/NixOS/nixpkgs/archive/$rev.tar.gz" ;;
      *) echo "get channel|rev|url" >&2; exit 2 ;;
    esac ;;
  github-env)
    valid || { echo "config/nixpkgs-pin.toml: channel or rev is missing or malformed" >&2; exit 1; }
    echo "NIXPKGS_REV=$rev"; echo "NIXPKGS_CHANNEL=$channel" ;;
  check)
    valid || { echo "config/nixpkgs-pin.toml: channel or rev is missing or malformed" >&2; exit 1; }
    # the revision lives in the pin file only (a copy in a workflow or script would drift)
    if hits=$(cd "$repo" && git grep -n -I -E '[0-9a-f]{40}' -- .github/workflows scripts installer install.nix configuration.nix 2>/dev/null | grep -i nixpkgs); then
      echo "a nixpkgs revision is written outside config/nixpkgs-pin.toml:" >&2; echo "$hits" >&2; exit 1
    fi
    echo "nixpkgs pin ok: $channel $rev" ;;
  latest) valid || exit 1; latest ;;
  bump)
    valid || { echo "config/nixpkgs-pin.toml: channel or rev is missing or malformed" >&2; exit 1; }
    new=""
    if [ "${2:-}" = --rev ]; then new=${3:-}; else new=$(latest); fi
    [[ "$new" =~ ^[0-9a-f]{40}$ ]] || { echo "no revision found for $channel" >&2; exit 1; }
    if [ "$new" = "$rev" ]; then echo unchanged; exit 0; fi
    sed -i "s/^rev *= *\"[0-9a-f]*\"/rev = \"$new\"/" "$pin"
    echo "$rev $new" ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
