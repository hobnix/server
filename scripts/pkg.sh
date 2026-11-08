#!/usr/bin/env bash
# help: packages (recipes and extensions): list them with their version, see which have an update, check the manifests
# help.de: Pakete (Rezepte und Erweiterungen): mit Version auflisten, Updates sehen, die Manifeste prüfen
# args: --market | --repos | list [--all] [--kind recipe|extension] | updates | validate | new <name> --template recipe|extension [--dir <path>] | fetch | available | install <name> | update <name> | remove <name> [--dry-run] | repo list|add|remove | --list
# A package is a recipe (packages/<name>/package.toml) or an extension (capabilities/<name>/package.toml) with a semver `version`
# (docs/PLAN-packages.md). This is step 1: the manifests of this repository only; repositories and `install` come later.
#   list        name, kind, version in the tree, version last applied here, who it is for; personal ones only with --all
#   --list      the same as data (hs sys pkg list): name, kind, version, installed (- = never), audience, title; every package
#   updates     the packages whose version in the tree is newer than the one last applied (`hs recipe <name>` applies a recipe)
#   validate    check every manifest (and that a recipe's header lines agree); lists the problems, exit 1 when there are any
#   new <name> --template recipe|extension [--dir <path>] [--title <text>] [--title-de <text>]   write a package that passes the checks into a
#               checkout of a package repository (recipes/<name> or extensions/<name>, plus its index.toml entry); never overwrites (pkg_new.py)
#   repo list|add|remove   the package repositories: the two defaults (config/package-repos.toml) and the ones a person added. Adding one
#                          shows the address and the signer key(s) and asks to TYPE the repository's name (--confirm-name <name> without a terminal);
#                          releases must be signed (--key <allowed_signers file>); --unsigned is marked everywhere and asks twice
#   fetch [<repo>]         update the local clones, find the newest release tag whose signature verifies
#   available              what the repositories offer (from the last fetch)
#   install --core         fetch every package the core refers to by name (core = true in the index) or that was applied here, when it is not there yet
#   install <name>         fetch a package at the verified tag into /var/lib/hs/packages/current (read-only, root-owned)
#   update <name> [--yes]  show what changed since the installed tag (it is code that runs as root), then install the new one
#   remove <name> [--dry-run] [--yes|--confirm-name <name>]
#                          uninstall a repository package: refused while it is switched on or another package that is on `requires` it
#                          (ADR 0009 rule 7). Shows what goes (the copy, its event declarations, its on/off marks) and what stays (containers
#                          and data, never deleted); --dry-run changes nothing; asks to type the name, or --yes / --confirm-name without a terminal
#   install and update refuse a package whose `requires_core` is above this server's API level (also checked against package.toml, not only the index)
# Test knobs: HS_PACKAGES_ROOT, HS_STATE_DIR, HS_LANG.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/live.sh"
py() { python3 -I "$here/pkg.py" "$@"; }
# a change of the packages or the repositories changes what the web interface shows (Marketplace, repositories, recipes, parts): the live
# state reads those topics again after it succeeded (a fetch always: one repository may have failed while the others moved); never fails it
pkg_changed() { trap 'rc=$?; [ "$rc" -ne 0 ] || live_refresh pkg-market pkg-repos recipes-list recipes-versions parts-list; exit "$rc"' EXIT; }

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
  new)
    shift
    name=${1:-}
    rc=0; out=$(py new "$@") || rc=$?
    if [ "$rc" -ne 0 ]; then
      line=$(sed -n 's/^error\t//p' <<<"$out"); code=${line%%$'\t'*}; detail=${line#*$'\t'}
      case "$code" in
        usage) say "usage: hs pkg new <name> --template recipe|extension [--dir <path>] [--title <text>] [--title-de <text>]"; exit 1 ;;
        template) fail "$(t 'Unknown template %s: use recipe or extension (a capability template waits for the service extensions, issue #238).' "$detail")" ;;
        name) fail "$(t 'The name %s is not allowed: lower case letters, digits and -, starting with a letter, at most 41 characters, and not list, enable or disable.' "$detail")" ;;
        title) fail "$(t 'A title is one line of at most 100 characters, without spaces at its ends.')" ;;
        notrepo) fail "$(t '%s is not a checkout of a package repository: it needs index.toml and the folder recipes/ (recipe) or extensions/ (extension). Use --dir <path>.' "$detail")" ;;
        exists) fail "$(t 'There is a package %s already (its folder or its index.toml entry); nothing was changed.' "$detail")" ;;
        *) fail "$(t 'The package could not be written (%s); nothing was left behind.' "$detail")" ;;
      esac
    fi
    folder=$(sed -n 's/^folder\t//p' <<<"$out"); name=$(basename "$folder"); index=$(sed -n 's/^index\t//p' <<<"$out")
    step "$(t 'New package %s' "$name")"
    kv "$(t 'Folder')" "$folder"
    while IFS= read -r f; do ok "$(t 'Created %s' "$f")"; done < <(sed -n 's/^file\t//p' <<<"$out")
    ok "$(t 'Added %s to %s' "$name" "$index")"
    note "$(t 'It passes the checks as it is. Replace the example step or command with your own, then check again:')"
    next_step "python3 -I $here/pkg.py repo-check $(dirname "$index")" ;;
  fetch)
    shift
    trap 'live_refresh pkg-market pkg-repos recipes-list recipes-versions parts-list' EXIT
    out=$(py fetch "$@") || rc=$?
    { thead 'Repository' 'Release' 'Commit' 'Result'; printf '%s\n' "$out"; } | table
    exit "${rc:-0}" ;;
  available)
    rows=$(py available)
    if [ -z "$rows" ]; then note "Nothing yet: hs pkg fetch"; exit 0; fi
    { thead 'Repository' 'Package' 'Kind' 'Version' 'Applied'; printf '%s\n' "$rows"; } | table
    next_step "hs pkg install <name>" ;;
  remove)
    shift; pkg_changed
    . "$here/lib/capability.sh"
    name=""; dry=0; yes=0; confirmed=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry=1; shift ;;
        --yes) yes=1; shift ;;
        --confirm-name) confirmed=${2:-}; shift 2 ;;
        -*) fail "$(t 'Unknown option %s' "$1")"; exit 1 ;;
        *) [ -z "$name" ] || { say "usage: hs pkg remove <name> [--dry-run] [--yes | --confirm-name <name>]"; exit 1; }; name=$1; shift ;;
      esac
    done
    [[ "$name" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || { say "usage: hs pkg remove <name> [--dry-run] [--yes | --confirm-name <name>]"; exit 1; }
    st=${HS_STATE_DIR:-/var/lib/hs}
    dir=$st/packages/current/$name
    [ -d "$dir" ] || { fail "$(t '%s was not installed from a repository.' "$name")"; exit 1; }
    mf() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p" "$2/package.toml" 2>/dev/null | head -n1; }
    kind=$(mf kind "$dir")
    # what keeps it: it is switched on itself, or a package that is on requires it (ADR 0009 rule 7)
    deps=""
    if [ "$kind" != recipe ] && capability_on "$name"; then
      fail "$(t "'%s' is switched on: switch it off first." "$name")"; next_step "hs ext disable $name"; exit 1
    fi
    for d in "$st"/packages/current/*/ "${HS_PACKAGES_ROOT:-$(dirname "$here")}"/capabilities/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d")
      [ "$n" != "$name" ] || continue
      f=$d/capability.toml; [ -f "$f" ] || f=$d/package.toml
      [ -f "$f" ] || continue
      sed -n 's/^requires[[:space:]]*=[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' "$f" | head -n1 | tr ',' '\n' | tr -d ' "' | grep -qxF -- "$name" || continue
      ! capability_on "$n" || deps+="${deps:+ }$n"
    done
    if [ -n "$deps" ]; then
      fail "$(t "'%s' cannot be removed: %s needs it." "$name" "$deps")"; next_step "hs ext disable ${deps%% *}"; exit 1
    fi
    step "$(t 'Remove package %s' "$name")"
    kv "$(t 'Version')" "$(mf version "$dir")"
    note "$(t 'Removed: the installed copy, its event declarations and its switch-on/off marks.')"
    note "$(t 'Stays: containers and data the package made (hs ct remove is for those).')"
    if [ "$dry" = 1 ]; then
      note "$(t 'Nothing was changed (dry run).')"
      exit 0
    fi
    if [ -n "$confirmed" ]; then
      [ "$confirmed" = "$name" ] || { fail "$(t 'The name does not match.')"; exit 1; }
    elif [ "$yes" = 0 ]; then
      if [ -t 0 ]; then
        confirm_name "$name" "$(t 'the package')" || { fail "$(t 'Not removed.')"; exit 1; }
      else
        fail "$(t 'Removing needs a person at a terminal, --yes or --confirm-name <name>.')"; exit 1
      fi
    fi
    py remove "$name"
    for o in on off; do
      f=$st/capabilities-$o
      [ -f "$f" ] || continue
      grep -vxF -- "$name" "$f" > "$f.tmp" || true
      mv "$f.tmp" "$f"
    done
    ok "$(t 'Package %s removed.' "$name")" ;;
  install)
    cmd=$1; shift
    pkg_changed
    if res=$(py "$cmd" "$@"); then
      if [ -z "$res" ]; then ok "$(t 'Done.')"; else while IFS= read -r l; do ok "$l"; done <<<"$res"; fi
    else exit 1; fi ;;
  update)
    shift; pkg_changed
    python3 -I "$here/pkg.py" update "$@" ;;
  repo)
    shift
    case "${1:-list}" in
      list)
        { thead 'Repository' 'Address' 'Signed' 'From'; py repo list; } | table ;;
      add)
        pkg_changed
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
      remove) shift; pkg_changed; py repo remove "${1:-}" && ok "$(t 'Repository removed.')" ;;
      *) say "usage: hs pkg repo list | add <name> <url> (--key <file> | --unsigned) | remove <name>"; exit 1 ;;
    esac ;;
  *) say "usage: hs pkg list [--all] [--kind recipe|extension] | updates | validate | new | fetch | available | install | update | remove | repo"; exit 1 ;;
esac
