# shellcheck shell=bash
# Update channels stable / beta / edge (docs/PLAN-channels.md): which ref `hs update` aims at. Needs ui.sh (fail_fix) for uc_verify.
#
#   uc_channel                 the setting updateChannel; anything unknown is stable
#   uc_target <repo> <channel> one line "<kind><TAB><ref><TAB><label>"; kind is tag, branch or none
#                              (none: no matching tag yet, callers keep the old "follow the current branch" behaviour; ref is -)
#   uc_verify <repo> <tag>     0 when the tag is signed with a key in config/trusted-keys/server.allowed_signers
#   uc_rank <channel>          0 stable, 1 beta, 2 edge (a higher number is a newer channel)
#   uc_last / uc_remember <c>  the channel the last update used (state file update-channel)
#
# Git runs as UC_OWNER (sudo -H -u) when that is set, like update.sh does. Test knobs: HS_STATE_DIR, HS_SETTINGS_DIR.
. "$(dirname "${BASH_SOURCE[0]}")/setting.sh"

_uc_git() {   # _uc_git <repo> <git args...>
  local repo=$1; shift
  if [ -n "${UC_OWNER:-}" ]; then sudo -H -u "$UC_OWNER" git -C "$repo" "$@"; else git -C "$repo" "$@"; fi
}

uc_channel() {
  case "$(setting_get updateChannel 2>/dev/null || true)" in
    beta) echo beta ;;
    edge) echo edge ;;
    *) echo stable ;;
  esac
}

uc_rank() {
  case "$1" in beta) echo 1 ;; edge) echo 2 ;; *) echo 0 ;; esac
}

uc_last() {
  local v=""
  [ ! -r "${HS_STATE_DIR:-/var/lib/hs}/update-channel" ] || IFS= read -r v < "${HS_STATE_DIR:-/var/lib/hs}/update-channel" || true
  case "$v" in beta|edge) echo "$v" ;; *) echo stable ;; esac
}

uc_remember() {
  mkdir -p "${HS_STATE_DIR:-/var/lib/hs}" 2>/dev/null || return 0
  printf '%s\n' "$1" > "${HS_STATE_DIR:-/var/lib/hs}/update-channel" 2>/dev/null || true
}

# the newest tag by semver order; the regex says which tags count (a release v1.4.0 sorts above v1.4.0-beta.2)
_uc_newest() {   # _uc_newest <repo> <extended regex>
  _uc_git "$1" tag --list 'v[0-9]*' | tr -d '\r' | { grep -E "$2" || true; } | awk '{
      t = $0; v = substr(t, 2); rel = 1; b = 0
      if (v ~ /-beta\./) { rel = 0; b = v; sub(/.*-beta\./, "", b); sub(/-beta\..*/, "", v) }
      split(v, p, "."); print p[1], p[2], p[3], rel, b, t }' |
    sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | tail -n 1 | awk '{ print $6 }'
}

uc_target() {
  local repo=$1 channel=$2 tag=""
  case "$channel" in
    edge) printf 'branch\torigin/develop\tdevelop\n'; return 0 ;;
    beta) tag=$(_uc_newest "$repo" '^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$') ;;
    *) tag=$(_uc_newest "$repo" '^v[0-9]+\.[0-9]+\.[0-9]+$') ;;
  esac
  if [ -n "$tag" ]; then printf 'tag\t%s\t%s\n' "$tag" "$tag"; else printf 'none\t-\tcurrent branch\n'; fi
}

uc_verify() {
  local repo=$1 tag=$2 signers out name
  signers=$repo/config/trusted-keys/server.allowed_signers
  if ! grep -qvE '^[[:space:]]*(#|$)' "$signers" 2>/dev/null; then
    fail_fix "$(t 'No release key is trusted for the core: %s is missing or empty, so no tag can be verified.' "$signers")" \
      "add the release key, see $repo/config/trusted-keys/README.md"
  fi
  if ! out=$(_uc_git "$repo" -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$signers" tag -v "$tag" 2>&1); then
    UC_VERIFY_OUT=$out
    return 1
  fi
  # the signed object must carry the very name that was asked for (an old signed tag cannot be passed off under a newer name)
  name=$(_uc_git "$repo" cat-file tag "$tag" 2>/dev/null | awk '$1 == "tag" { print $2; exit } NF == 0 { exit }' | tr -d '\r')
  if [ "$name" != "$tag" ]; then
    UC_VERIFY_OUT="the signed tag is named '${name:-?}', not '$tag'"
    return 1
  fi
  return 0
}

# uc_state <repo> <kind> <ref>: what `hs update` would do with the target, from refs already fetched (nothing is fetched):
# none (no target yet), unknown (the ref is not in this checkout), current (HEAD is the target), kept (the target is part of HEAD: the installed
# version stays until the channel catches up, no downgrade), update (the target is newer or on another line).
uc_state() {
  local repo=$1 kind=$2 ref=$3 target head
  if [ "$kind" != tag ] && [ "$kind" != branch ]; then echo none; return 0; fi
  target=$(_uc_git "$repo" rev-parse --verify -q "$ref^{commit}" 2>/dev/null) || { echo unknown; return 0; }
  head=$(_uc_git "$repo" rev-parse HEAD 2>/dev/null) || { echo unknown; return 0; }
  if [ "$target" = "$head" ]; then echo current
  elif _uc_git "$repo" merge-base --is-ancestor "$target" "$head" 2>/dev/null; then echo kept
  else echo update; fi
}
