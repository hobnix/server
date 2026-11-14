# shellcheck shell=bash
# The Hobnix version of this server (issue #400): one line, no prefix.
#   hobnix_version [repo]   `git describe --tags --always` of the repository (default HS_REPO or /etc/nixos): a tag (v0.1.0), a commit after a
#                           tag (v0.1.0-3-gabc1234) or a bare short hash before the first tag. Without a git checkout (an install that had
#                           no network, docs/install.md) the version the installer kept in <repo>/.hobnix-version; otherwise "-".
# Read only, fetches nothing. Test knob: HS_REPO.
hobnix_version() {
  local repo=${1:-${HS_REPO:-/etc/nixos}} v=""
  v=$(git -C "$repo" describe --tags --always 2>/dev/null || true)
  if [ -z "$v" ] && [ -r "$repo/.hobnix-version" ]; then IFS= read -r v < "$repo/.hobnix-version" || true; fi
  [[ "$v" =~ ^[A-Za-z0-9._+-]+$ ]] || v=""
  printf '%s\n' "${v:--}"
}
