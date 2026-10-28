#!/usr/bin/env bash
# help: how many new commits the checkout is behind its upstream (from refs that are already fetched; fetches nothing)
# help.de: wie viele neue Commits der Checkout hinter seinem Upstream liegt (aus schon geholten Refs; holt nichts)
# args: (none)
# hs sys system updates: machine-readable, plain, tab separated rows for the web interface (the count tag of the Update button):
#   behind <n>      commits upstream has that HEAD does not (what `hs update` would pull)
#   ahead <n>       commits HEAD has that upstream does not
#   upstream <ref>  the upstream branch ("-" = the checkout has none)
#   fetched <epoch> when the refs were last fetched (mtime of FETCH_HEAD, "-" = never)
# A read must not touch the network: this never runs `git fetch`; the count is as old as the last fetch (hs update, hs update --preview).
# Test knob: HS_REPO (the checkout).
set -euo pipefail
repo=${HS_REPO:-/etc/nixos}

none() { printf 'behind\t0\nahead\t0\nupstream\t-\nfetched\t-\n'; }

if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then none; exit 0; fi
owner=$(stat -c %U "$repo" 2>/dev/null || echo root)
if [ "$(id -u)" = 0 ] && [ "$owner" != root ]; then
  g() { sudo -H -u "$owner" git -C "$repo" "$@"; }
else
  g() { git -C "$repo" "$@"; }
fi

up=$(g rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
if [ -z "$up" ]; then none; exit 0; fi
behind=$(g rev-list --count "HEAD..$up" 2>/dev/null || echo 0)
ahead=$(g rev-list --count "$up..HEAD" 2>/dev/null || echo 0)
gitdir=$(g rev-parse --absolute-git-dir 2>/dev/null || true)
fetched=-
if [ -n "$gitdir" ] && [ -e "$gitdir/FETCH_HEAD" ]; then fetched=$(stat -c %Y "$gitdir/FETCH_HEAD" 2>/dev/null || echo -); fi
printf 'behind\t%s\nahead\t%s\nupstream\t%s\nfetched\t%s\n' "$behind" "$ahead" "$up" "$fetched"
