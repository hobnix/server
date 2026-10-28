#!/usr/bin/env bash
# help: look at what hs update would do (changes from Git, new machine.toml options, what the rebuild would restart) without applying anything
# help.de: zeigt, was hs update tun würde (Änderungen aus Git, neue Optionen für machine.toml, was der Neubau neu starten würde), ohne etwas anzuwenden
# args: [--no-build]
# Only `git fetch` runs (it changes no file of the config). Three parts: (1) the commits and the diffstat
# between your checkout and its upstream, (2) the options of the upstream machine.toml.example that your
# machine.toml does not have yet (machine-sync --list), (3) the upstream version built as a dry run:
# `nixos-rebuild dry-activate` as root (which units would restart), else `nix-build --dry-run` (what would
# be built or downloaded). --no-build skips part 3 (it can take minutes).
# Test knobs: HS_REPO (the checkout), HS_MACHINE_FILE, HS_PREVIEW_AS_ROOT (take the root path of part 3).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/ui.sh"

repo=${HS_REPO:-/etc/nixos}
machine=${HS_MACHINE_FILE:-$repo/machine.toml}
build=true
for a in "$@"; do
  case "$a" in
    --no-build) build=false ;;
    *) say "usage: hs update --preview [--no-build]"; exit 1 ;;
  esac
done

[ -d "$repo/.git" ] || [ -f "$repo/.git" ] || fail "$(t 'No Git checkout in %s.' "$repo")"

# git as the owner of the checkout when running as root (like update.sh)
owner=$(stat -c %U "$repo")
if [ "$(id -u)" = 0 ] && [ "$owner" != root ]; then
  g() { sudo -H -u "$owner" git -C "$repo" "$@"; }
else
  g() { git -C "$repo" "$@"; }
fi

step "Preview of the update"
if ! spin "Fetching what is new (nothing is applied)" g fetch --quiet; then
  note "Is there a network connection to the Git server?"
  exit 1
fi

up=$(g rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
[ -n "$up" ] || fail "$(t 'The checkout has no upstream branch, so there is nothing to compare with.')"

behind=$(g rev-list --count "HEAD..$up")
ahead=$(g rev-list --count "$up..HEAD")

# 1. changes from Git
if [ "$behind" -eq 0 ]; then
  ok "Already the latest configuration: hs update would only rebuild"
else
  ok "$(t '%s new change(s) from %s:' "$behind" "$up")"
  g log --format='%h %s' -n 15 "HEAD..$up" | while IFS= read -r line; do note "$line"; done   # git limits the lines (no pipe into head: SIGPIPE + pipefail)
  [ "$behind" -le 15 ] || note "$(t '... and %s more' "$((behind - 15))")"
  echo
  g diff --stat=100 "HEAD...$up" | tail -n 25 | sed 's/^/      /'
fi
if [ "$ahead" -gt 0 ]; then
  warn "$(t 'This checkout has %s commit(s) that are not upstream: hs update (pull --ff-only) may refuse.' "$ahead")"
fi
dirty=$(g status --porcelain --untracked-files=no | wc -l)
if [ "$dirty" -gt 0 ] && [ "$behind" -gt 0 ]; then
  clash=$(comm -12 <(g status --porcelain --untracked-files=no | sed 's/^...//' | sort) <(g diff --name-only "HEAD...$up" | sort) || true)
  if [ -n "$clash" ]; then
    warn "Local changes in files that change upstream too: hs update would stop."
    sed 's/^/      /' <<<"$clash"
  fi
fi

# 2. new machine.toml options (from the upstream example, so the options the update brings show up)
step "New options for machine.toml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
example=$repo/machine.toml.example
if [ "$behind" -gt 0 ] && g show "$up:machine.toml.example" > "$tmp/machine.toml.example" 2>/dev/null; then
  example=$tmp/machine.toml.example
fi
if [ ! -f "$machine" ]; then
  if [ -f "$(dirname "$machine")/machine.nix" ]; then
    note "hs update converts machine.nix to machine.toml (the old file is kept as machine.nix.migrated)."
  else
    note "$(t 'No %s yet.' "$machine")"
  fi
elif [ ! -f "$example" ]; then
  note "$(t 'No %s.' "$example")"
else
  new=$(HS_MACHINE_FILE=$machine HS_MACHINE_EXAMPLE=$example bash "$here/machine-sync.sh" --list 2>/dev/null || true)
  if [ -n "$new" ]; then
    while IFS=$'\t' read -r _ key desc; do line "$key"; note "$desc"; done <<<"$new"
    note "hs update adds them to machine.toml, commented out, and asks whether to stop before the rebuild."
  else
    ok "Nothing new: machine.toml has every option"
  fi
fi

# 3. dry run of the build
if ! $build; then
  note "The build preview was skipped (--no-build)."
  exit 0
fi
step "What the rebuild would do"
src=$repo
if [ "$behind" -gt 0 ]; then
  # the upstream version in a scratch copy, with this server's own files next to it
  mkdir -p "$tmp/cfg"
  g archive "$up" | tar -x -C "$tmp/cfg"
  for f in machine.toml machine.nix hardware-configuration.nix; do
    [ ! -f "$repo/$f" ] || cp "$repo/$f" "$tmp/cfg/$f"
  done
  [ -z "${HS_MACHINE_FILE:-}" ] || cp "$machine" "$tmp/cfg/machine.toml"
  src=$tmp/cfg
fi
cfg=$src/configuration.nix
is_root=false
{ [ "$(id -u)" = 0 ] || [ -n "${HS_PREVIEW_AS_ROOT:-}" ]; } && is_root=true
if $is_root && command -v nixos-rebuild >/dev/null 2>&1; then
  if SPIN_TAIL=15 spin "Building the new system as a dry run (many minutes after big changes)" nixos-rebuild dry-activate -I "nixos-config=$cfg"; then
    acts=$(grep -E '^(would|the following|these)' <<<"$spin_out" | grep -v '^building' || true)
    units=$(grep -E '^  ' <<<"$spin_out" | head -n 30 || true)
    if [ -n "$acts" ]; then
      printf '%s\n' "$acts" | sed 's/^/      /'
      [ -z "$units" ] || printf '%s\n' "$units" | sed 's/^/      /'
    else
      ok "No unit would be restarted"
    fi
  else
    warn "The new configuration does not build. Do not run hs update before this is fixed."
    exit 1
  fi
elif command -v nix-build >/dev/null 2>&1; then
  note "Not root: only what would be built or downloaded is shown (run with sudo for the unit list)."
  if SPIN_TAIL=15 spin "Evaluating the new system as a dry run" nix-build '<nixpkgs/nixos>' -A system -I "nixos-config=$cfg" --dry-run; then
    sum=$(grep -E 'will be (built|fetched)|^  /nix/store' <<<"$spin_out" | grep -E 'will be' || true)
    if [ -n "$sum" ]; then printf '%s\n' "$sum" | sed 's/^/      /'; else ok "Nothing to build: everything is in the store already"; fi
  else
    warn "The new configuration does not evaluate. Do not run hs update before this is fixed."
    exit 1
  fi
else
  note "Neither nixos-rebuild nor nix-build found: the build preview is skipped."
fi
note "Nothing was applied. To apply it: hs update"
