#!/usr/bin/env bash
# help: packages (recipes and extensions): list them with their version, see which have an update, check the manifests
# help.de: Pakete (Rezepte und Erweiterungen): mit Version auflisten, Updates sehen, die Manifeste prüfen
# args: --market | --repos | list [--all] [--kind recipe|extension] | updates | validate | fetch | available | install <name> | update <name> | remove <name> | repo list|add|remove | --list
# A package is a recipe (packages/<name>/package.toml) or an extension (capabilities/<name>/package.toml) with a semver `version`
# (docs/PLAN-packages.md). This is step 1: the manifests of this repository only; repositories and `install` come later.
#   list        name, kind, version in the tree, version last applied here, who it is for; personal ones only with --all
#   --list      the same as data (hs sys pkg list): name, kind, version, installed (- = never), audience, title; every package
#   updates     the packages whose version in the tree is newer than the one last applied (`hs recipe <name>` applies a recipe)
#   validate    check every manifest (and that a recipe's header lines agree); lists the problems, exit 1 when there are any
#   repo list|add|remove   the package repositories: the two defaults (config/package-repos.toml) and the ones a person added. Adding one
#                          shows the address and the signer key(s) and asks to TYPE the repository's name (--confirm-name <name> without a terminal);
#                          releases must be signed (--key <allowed_signers file>); --unsigned is marked everywhere and asks twice
#   fetch [<repo>]         update the local clones, find the newest release tag whose signature verifies
#   available              what the repositories offer (from the last fetch)
#   install --core         fetch every package the core refers to by name (core = true in the index) or that was applied here, when it is not there yet
#   install <name>         fetch a package at the verified tag into /var/lib/hs/packages/current (read-only, root-owned)
#   update <name> [--yes]  show what changed since the installed tag (it is code that runs as root), then install the new one
#   remove <name>          forget an installed repository package (a recipe's container stays)
# Test knobs: HS_PACKAGES_ROOT, HS_STATE_DIR, HS_LANG.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
py() { python3 -I "$here/pkg.py" "$@"; }

case "${1:-list}" in
  --list) py list --all ;;
  --market) py market ;;
  --repos) py repo list ;;
  list)
    shift
    rows=$(py list "$@")
    if [ -z "$rows" ]; then note "No packages."; exit 0; fi
    { thead 'Package' 'Kind' 'Version' 'Applied' 'For' 'What it is'; printf '%s\n' "$rows"; } | table
    next_step "hs pkg updates" ;;
  updates)
    rows=$(py updates)
    if [ -z "$rows" ]; then ok "$(t 'Every package is up to date.')"; exit 0; fi
    { thead 'Package' 'Applied' 'Available'; printf '%s\n' "$rows"; } | table
    next_step "hs recipe <name>" ;;
  validate)
    if out=$(py validate); then ok "$(t 'Every manifest is valid.')"; else
      while IFS=$'\t' read -r n p; do warn "$n: $p"; done <<<"$out"
      exit 1
    fi ;;
  fetch)
    shift
    out=$(py fetch "$@") || rc=$?
    { thead 'Repository' 'Release' 'Commit' 'Result'; printf '%s\n' "$out"; } | table
    exit "${rc:-0}" ;;
  available)
    rows=$(py available)
    if [ -z "$rows" ]; then note "Nothing yet: hs pkg fetch"; exit 0; fi
    { thead 'Repository' 'Package' 'Kind' 'Version' 'Applied'; printf '%s\n' "$rows"; } | table
    next_step "hs pkg install <name>" ;;
  install|remove)
    cmd=$1; shift
    if res=$(py "$cmd" "$@"); then
      if [ -z "$res" ]; then ok "$(t 'Done.')"; else while IFS= read -r l; do ok "$l"; done <<<"$res"; fi
    else exit 1; fi ;;
  update)
    shift; exec python3 -I "$here/pkg.py" update "$@" ;;
  repo)
    shift
    case "${1:-list}" in
      list)
        { thead 'Repository' 'Address' 'Signed' 'From'; py repo list; } | table ;;
      add)
        name=${2:-}; url=${3:-}; [ -n "$name" ] && [ -n "$url" ] || { say "usage: hs pkg repo add <name> <url> (--key <allowed_signers file> | --unsigned) [--confirm-name <name>]"; exit 1; }
        shift 3; confirmed=""; extra=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --confirm-name) confirmed=${2:-}; shift 2 ;;
            *) extra+=("$1"); shift ;;
          esac
        done
        step "$(t 'Package repository %s' "$name")"
        kv "$(t 'Address')" "$url"
        key=""; unsigned=false
        for ((i = 0; i < ${#extra[@]}; i++)); do
          [ "${extra[i]}" != --key ] || key=${extra[i + 1]:-}
          [ "${extra[i]}" != --unsigned ] || unsigned=true
        done
        if [ -n "$key" ] && [ -r "$key" ]; then
          while read -r line; do
            kv "$(t 'Signer')" "$(sed -E 's/^.*(ssh-[a-z0-9]+|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+) /\1 /' <<<"$line" | ssh-keygen -lf /dev/stdin 2>/dev/null || echo "$line")"
          done < <(grep -v '^#' "$key" | grep -v '^[[:space:]]*$')
        fi
        if $unsigned; then
          danger "$(t 'UNSIGNED: anyone who controls this address can run code on this server as root.')"
        fi
        danger "$(t 'Packages run as root. Only add a repository you trust.')"
        if [ -n "$confirmed" ]; then
          [ "$confirmed" = "$name" ] || { fail "$(t 'The name does not match.')"; exit 1; }
        elif [ -t 0 ]; then
          confirm_name "$name" "$(t 'the repository')" || { fail "$(t 'Not added.')"; exit 1; }
          if $unsigned; then confirm_name "$name" "$(t 'the repository, again: it is unsigned')" || { fail "$(t 'Not added.')"; exit 1; }; fi
        else
          fail "$(t 'Adding a repository needs a person at a terminal, or --confirm-name <name>.')"; exit 1
        fi
        py repo add "$name" "$url" "${extra[@]}" && ok "$(t 'Repository %s added.' "$name")" && next_step "hs pkg fetch $name" ;;
      remove) shift; py repo remove "${1:-}" && ok "$(t 'Repository removed.')" ;;
      *) say "usage: hs pkg repo list | add <name> <url> (--key <file> | --unsigned) | remove <name>"; exit 1 ;;
    esac ;;
  *) say "usage: hs pkg list [--all] [--kind recipe|extension] | updates | validate | fetch | available | install | update | remove | repo"; exit 1 ;;
esac
