#!/usr/bin/env bash
# help: install, update or remove a package, fetch the repositories, add or remove a repository, without asking anything: what would happen (plan), then do it (start)
# help.de: ein Paket installieren, aktualisieren oder entfernen, die Repositories abrufen, ein Repository hinzufügen oder entfernen, ohne etwas zu fragen: was passieren würde (plan), dann ausführen (start)
# args: plan|start install <name> [--repo R] | update <name> | remove <name> | fetch [<repo>] | repo-add <name> <url> | repo-remove <name>
# System command (hs sys pkg plan|start): for the interface (Marketplace) and tests. It never asks and prints plain key<TAB>value lines like
# node-change.sh. The work is pkg.sh's (hs pkg install|update|remove|fetch|repo ...); this script checks the input and says what would happen.
#   install <name> [--repo R]  fetch the package at the verified release into /var/lib/hs/packages/current (it is not run: a recipe is run from Apps)
#   update <name>              install the newer release; the plan shows what changed in the code (it runs as root)
#   remove <name>              forget a package installed from a repository; a container made by a recipe stays
#   fetch [<repo>]             read the repositories again and find the newest verified release (needs the network)
#   repo-add <name> <url>      add a repository; its public signing key is ONE line on standard input (ssh-ed25519 AAAA..., or a whole
#                              allowed-signers line). Only signed repositories can be added here (an unsigned one is `hs pkg repo add --unsigned`).
#                              The release is fetched at once; if nothing verifies the repository is taken out again. Red: the typed word is the name.
#   repo-remove <name>         take an added repository out (the defaults stay); installed packages stay as they are. Red: the typed word is the name.
# A package from a repository that was ADDED (not recipes/extensions of this project) runs as root once installed: install and update are red
# for it, the typed word is the package name. For the default repositories the plan is the confirmation.
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note|warn|danger|command|diff<TAB><line>,
#   confirm_name<TAB><name>, long<TAB>yes|no (yes = the network is used).
# start: the same checks, then status<TAB>done (or refused with the reason).
# Test knobs: HS_PKG (stand-in for pkg.sh), HS_PKG_ALLOW_LOCAL=1 (a repository may be a local path or file://).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkg=${HS_PKG:-$here/pkg.sh}
pkgpy="python3 -I $here/pkg.py"

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}; name=${3:-}
case "$verb" in plan|start) ;; *) echo "usage: pkg-change.sh plan|start install|update|remove <name> | fetch [<repo>] | repo-add <name> <url> | repo-remove <name>" >&2; exit 1 ;; esac
case "$action" in install|update|remove|fetch|repo-add|repo-remove) ;; *) refuse "unknown action (install, update, remove, fetch, repo-add or repo-remove)" ;; esac
shift 2 || true
name=${1:-}; [ $# -eq 0 ] || shift

# the web interface appends --confirm <word> to start (the typed name of a red change); take it out of the arguments
confirm="" rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm) [ $# -ge 2 ] || refuse "--confirm needs a value"; confirm=$2; shift 2 ;;
    *) rest+=("$1"); shift ;;
  esac
done
set -- ${rest[@]+"${rest[@]}"}

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY

word='^[a-z0-9][a-z0-9-]{0,40}$'
market() { bash "$pkg" --market 2>/dev/null || true; }
repos() { bash "$pkg" --repos 2>/dev/null || true; }
# one line per fact: name, kind, repo, available, installed, state, core, audience, title
row_of() { market | awk -F'\t' -v n="$1" '$1 == n { print; exit }'; }
repo_row() { repos | awk -F'\t' -v n="$1" '$1 == n { print; exit }'; }   # name, address, signed|unsigned, default|added

repo="" cmd=() red="" long=no
case "$action" in
  install|update|remove)
    [[ "$name" =~ $word ]] || refuse "not a package name (lower case letters, digits and dashes)"
    row=$(row_of "$name")
    [ -n "$row" ] || refuse "There is no package $name in the repositories (fetch them again first)."
    IFS=$'\t' read -r _ kind repo avail inst state core _ title <<<"$row"
    r_from=$(repo_row "$repo" | cut -f4)
    [ "$r_from" = added ] && red=$name
    case "$action" in
      install)
        while [ $# -gt 0 ]; do
          case "$1" in
            --repo) repo=${2:-}; [ -n "$repo" ] || refuse "--repo needs a name"; shift 2 ;;
            *) refuse "unknown option $1" ;;
          esac
        done
        [ "$state" = new ] || refuse "$name is installed already (version $inst); use update."
        cmd=(bash "$pkg" install "$name" --repo "$repo") ;;
      update)
        [ $# -eq 0 ] || refuse "unexpected extra arguments"
        [ "$inst" != - ] || refuse "$name is not installed from a repository; install it first."
        [ "$state" = update ] || refuse "$name is up to date (version $inst)."
        cmd=(bash "$pkg" update "$name" --yes) ;;
      remove)
        [ $# -eq 0 ] || refuse "unexpected extra arguments"
        [ "$inst" != - ] || refuse "$name is not installed from a repository."
        [ "$core" != yes ] || refuse "$name is a core package: other parts of the server refer to it by name, so it stays."
        red=""
        cmd=(bash "$pkg" remove "$name") ;;
    esac ;;
  fetch)
    repo=$name; name=""
    [ $# -eq 0 ] || refuse "unexpected extra arguments"
    if [ -n "$repo" ]; then [[ "$repo" =~ $word ]] && [ -n "$(repo_row "$repo")" ] || refuse "There is no repository $repo."; fi
    long=yes
    cmd=(bash "$pkg" fetch); [ -z "$repo" ] || cmd+=("$repo") ;;
  repo-add)
    url=${1:-}; [ $# -eq 0 ] || shift
    [ $# -eq 0 ] || refuse "unexpected extra arguments"
    [[ "$name" =~ $word ]] || refuse "the repository name is a lower case word (letters, digits and dashes)"
    [ -z "$(repo_row "$name")" ] || refuse "There is a repository called $name already."
    [ -n "$url" ] || refuse "the address of the repository is needed"
    if [ "${HS_PKG_ALLOW_LOCAL:-}" = 1 ]; then ok_url='^(https://|ssh://|git@|file://|/)[A-Za-z0-9._:/@~+-]{2,200}$'; else ok_url='^(https://|ssh://git@|git@)[A-Za-z0-9._:/@~+-]{3,200}$'; fi
    [[ "$url" =~ $ok_url ]] && [[ "$url" != *..* ]] || refuse "the address must be https://..., ssh://git@... or git@host:path"
    red=$name; long=yes ;;
  repo-remove)
    [[ "$name" =~ $word ]] || refuse "not a repository name"
    r=$(repo_row "$name"); [ -n "$r" ] || refuse "There is no repository $name."
    [ "$(cut -f4 <<<"$r")" = added ] || refuse "$name is one of the default repositories: those stay."
    red=$name ;;
esac

if [ "$verb" = start ]; then
  if [ -n "$red" ]; then [ "$confirm" = "$red" ] || refuse "type the name ($red) to confirm"; fi
  case "$action" in
    repo-add)
      # the signing key: one line on standard input, rebuilt as an allowed-signers line (principal, git namespace, type, key)
      IFS= read -r line || true
      [ -n "$line" ] || refuse "the public signing key of the repository is needed"
      if ! [[ "$line" =~ (ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)[[:space:]]+([A-Za-z0-9+/]{20,}={0,3}) ]]; then
        refuse "that is not an SSH public key (it starts with ssh-ed25519 or ssh-rsa)"
      fi
      keyfile=$(mktemp "${TMPDIR:-/tmp}/hs-pkg-key.XXXXXX"); trap 'rm -f "$keyfile"' EXIT
      printf 'release@%s namespaces="git" %s %s\n' "$name" "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" > "$keyfile"
      rc=0; out=$(bash "$pkg" repo add "$name" "$url" --key "$keyfile" --confirm-name "$name" </dev/null 2>&1) || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf 'status\trefused\nreason\t%s\n' "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"; exit 1
      fi
      rc=0; out=$(bash "$pkg" fetch "$name" </dev/null 2>&1) || rc=$?
      if [ "$rc" -ne 0 ] || ! market | awk -F'\t' -v r="$name" '$3 == r { f = 1 } END { exit !f }'; then
        bash "$pkg" repo remove "$name" </dev/null >/dev/null 2>&1 || true
        printf 'status\trefused\nreason\t%s\n' "no signed release could be read from that address with that key (the repository was not kept)"; exit 1
      fi
      printf 'status\tdone\n'; exit 0 ;;
    repo-remove)
      rc=0; out=$(bash "$pkg" repo remove "$name" </dev/null 2>&1) || rc=$? ;;
    *)
      rc=0; out=$("${cmd[@]}" </dev/null 2>&1) || rc=$? ;;
  esac
  if [ "$rc" -ne 0 ]; then
    printf 'status\trefused\nreason\t%s\n' "$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/^[✗!] *//' | awk 'NF' | tail -n 1)"
    exit 1
  fi
  printf 'status\tdone\n'
  exit 0
fi

printf 'status\tok\n'
case "$action" in
  install)
    printf 'heading\tinstall %s %s\n' "$name" "$avail"
    printf 'step\tfetch %s %s from the signed release of the repository %s\n' "$kind" "$name" "$repo"
    printf 'note\t%s\n' "$title"
    if [ "$kind" = recipe ]; then printf 'note\tThis only puts the recipe on the server. Run it from Apps to set the app up.\n'; else printf 'note\tAn extension is off until you switch it on.\n'; fi
    if [ -n "$red" ]; then
      printf 'danger\tThe repository %s was added by you, not by the project. This package runs as root on this server.\n' "$repo"
      printf 'confirm_name\t%s\n' "$name"
    fi ;;
  update)
    printf 'heading\tupdate %s %s -> %s\n' "$name" "$inst" "$avail"
    printf 'step\tinstall the newer signed release; the code below changed and runs as root\n'
    $pkgpy update "$name" </dev/null 2>/dev/null | head -n 60 | while IFS= read -r l; do printf 'diff\t%s\n' "$l"; done || true
    if [ -n "$red" ]; then
      printf 'danger\tThe repository %s was added by you, not by the project.\n' "$repo"
      printf 'confirm_name\t%s\n' "$name"
    fi ;;
  remove)
    printf 'heading\tremove %s\n' "$name"
    printf 'step\tforget the installed copy of %s (version %s)\n' "$name" "$inst"
    printf 'note\tA container or data made by the recipe stays; hs pkg install brings the package back.\n' ;;
  fetch)
    printf 'heading\tread the repositories again\n'
    printf 'step\tfetch %s and find the newest release whose signature verifies\n' "${repo:-every repository}"
    printf 'note\tNothing is installed or changed; the list of packages is refreshed.\n' ;;
  repo-add)
    printf 'heading\tadd the repository %s\n' "$name"
    printf 'step\tuse %s as a source of packages; only releases signed with the key you give are accepted\n' "$url"
    printf 'step\tfetch its newest release at once; if nothing verifies, the repository is not kept\n'
    printf 'danger\tPackages run as root on this server. Only add a repository whose owner you trust.\n'
    printf 'confirm_name\t%s\n' "$name" ;;
  repo-remove)
    printf 'heading\tremove the repository %s\n' "$name"
    printf 'step\tstop using %s and delete its cache and its key\n' "$name"
    printf 'danger\tPackages already installed from it stay as they are, but get no updates.\n'
    printf 'confirm_name\t%s\n' "$name" ;;
esac
[ "${#cmd[@]}" -eq 0 ] || printf 'command\t%s\n' "${cmd[*]}"
printf 'long\t%s\n' "$long"
