# shellcheck shell=bash
# The command list as every reader sees it: scripts/lib/registry.tsv (the core) plus the commands.tsv of every ENABLED package
# (docs/PLAN-extensions.md). A package is a folder capabilities/<name>/ (later also /var/lib/hs/packages/<name>@<commit>); it is
# enabled when the capability <name> is on (scripts/lib/capability.sh). The hs dispatcher, `hs help`, completion, docs-build,
# the cheat sheet, smoke, tests/commands.sh and the web allowlists all read the list through registry_rows, never the file.
#
#   registry_rows                   the merged rows (kind path script args help help.de flags), comment lines removed
#   registry_rows_of <name>         the valid rows of ONE package, also while it is off (hs ext <name>)
#   registry_refused [<name>]       the rows a package may not carry, one per line: package TAB line TAB path TAB reason
#   ext_package_names               every package (a folder with commands.tsv or `extension = true`), one per line
#   ext_package_dir <name>          the folder of a package (the ONE place that knows where packages live)
#   ext_package_on <name>           true when the package is enabled
#   ext_core_file                   the core registry file
#
# Rules for the rows of a package (anything else is refused and left out, never loaded):
#   - user rows are `ext <name> <command...>`, sys rows `sys ext <name> <command...>`: the folder name is the namespace, so a package
#     can neither collide with another one nor shadow a core command. `hs ext <name>` alone lists the package, it is not a row.
#   - the script is a path under scripts/ (like the core), or `@/file` = a file inside the package folder (rewritten to the folder).
#     No `..`, no other absolute path.
#   - no `legacy:` flag (the old words of a moved command are rows of the core registry), no second row for the same words.
#   - the names list, enable and disable are reserved (they are the core commands `hs ext list|enable|disable`).
# Test knobs: HS_REGISTRY (core file), HS_PACKAGES_DIR (the folder that holds the packages; only that one is read).
. "$(dirname "${BASH_SOURCE[0]}")/capability.sh"

_ext_lib=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ext_core_file() { echo "${HS_REGISTRY:-$_ext_lib/registry.tsv}"; }

# The folders that hold packages, in order. On the server the scripts run from a copy in /nix/store that has no capabilities/:
# the checkout in /etc/nixos is the source then. A later /var/lib/hs/packages/<name>@<commit> location is added in ext_package_dir.
_ext_roots() {
  local r
  if [ -n "${HS_PACKAGES_DIR:-}" ]; then echo "$HS_PACKAGES_DIR"; return 0; fi
  # extensions live in capabilities/, recipes in packages/ (a recipe package carries commands.tsv and a page just like an extension)
  local base sub
  base=$(cd "$(dirname "$(ext_core_file)")/../.." 2>/dev/null && pwd)
  for sub in capabilities packages; do
    r=$base/$sub
    [ ! -d "$r" ] || echo "$r"
    if [ -z "${HS_REGISTRY:-}" ] && [ "$r" != "/etc/nixos/$sub" ] && [ -d "/etc/nixos/$sub" ]; then echo "/etc/nixos/$sub"; fi
  done
  # the packages installed from a repository (hs pkg install): a read-only copy per package, written by scripts/pkg_repo.py
  r=${HS_STATE_DIR:-/var/lib/hs}/packages/current
  [ ! -d "$r" ] || echo "$r"
  return 0
}

# A package folder: an extension (capability.toml) or a recipe that brings commands (package.toml with kind = "recipe" and a commands.tsv).
_ext_is_package() { [ -f "$1/capability.toml" ] || { [ -f "$1/package.toml" ] && [ -f "$1/commands.tsv" ] && grep -qE '^kind[[:space:]]*=[[:space:]]*"recipe"' "$1/package.toml"; }; }

ext_package_dir() {   # ext_package_dir <name>
  local r
  [[ "${1:-}" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || return 1
  while IFS= read -r r; do
    if _ext_is_package "$r/$1"; then echo "$r/$1"; return 0; fi
  done < <(_ext_roots)
  # later: /var/lib/hs/packages/$1@<pinned commit> (docs/PLAN-extensions.md, "Packages from a repository")
  return 1
}

ext_package_names() {
  local r d n
  while IFS= read -r r; do
    for d in "$r"/*/; do
      _ext_is_package "${d%/}" || continue
      n=$(basename "$d")
      if [ -f "${d}commands.tsv" ] || grep -qE '^extension[[:space:]]*=[[:space:]]*true' "${d}capability.toml" 2>/dev/null; then echo "$n"; fi
    done
  done < <(_ext_roots) | sort -u
}

# An extension is on when its capability is; a recipe package is "on" once the recipe has been applied on this server (installed.toml).
ext_package_on() {
  local d
  d=$(ext_package_dir "$1") || return 1
  if [ -f "$d/capability.toml" ]; then capability_on "$1"; return; fi
  grep -qxF "[package.$1]" "${HS_STATE_DIR:-/var/lib/hs}/packages/installed.toml" 2>/dev/null
}

# Reads one commands.tsv. Valid rows go to stdout, or with report=1 the refused ones as REFUSED TAB line TAB path TAB reason.
_ext_filter() {   # _ext_filter <name> <dir> <report 0|1>
  [ -f "$2/commands.tsv" ] || return 0
  awk -F'\t' -v OFS='\t' -v name="$1" -v dir="$2" -v report="$3" '
    /^#/ || /^[ \t\r]*$/ { next }
    {
      sub(/\r$/, "")
      kind = $1; path = $2; script = $3; reason = ""
      nw = split(path, w, " ")
      if (name == "list" || name == "enable" || name == "disable") reason = "the name " name " is reserved (hs ext " name ")"
      else if (kind == "user") { if (w[1] != "ext" || w[2] != name || nw < 3) reason = "a user row must be: ext " name " <command>" }
      else if (kind == "sys")  { if (w[1] != "sys" || w[2] != "ext" || w[3] != name || nw < 4) reason = "a sys row must be: sys ext " name " <command>" }
      else reason = "the kind must be user or sys"
      if (reason == "" && NF < 6) reason = "a row has at least 6 columns (kind path script args help help.de)"
      if (reason == "" && (script == "" || script ~ /(^|\/)\.\.(\/|$)/ || (script ~ /^\// ))) reason = "the script must be a path under scripts/ or @/file in the package, without .."
      if (reason == "" && script ~ /^@/ && script !~ /^@\/./) reason = "the script must be a path under scripts/ or @/file in the package, without .."
      if (reason == "" && $7 ~ /(^|,)legacy:/) reason = "a legacy: flag belongs to the core registry"
      if (reason == "" && (path in seen)) reason = "the words are used twice"
      if (reason != "") { if (report == 1) print "REFUSED", NR, path, reason; next }
      seen[path] = 1
      if (report == 1) next
      if (script ~ /^@\//) $3 = dir "/" substr(script, 3)
      print
    }' "$2/commands.tsv"
}

registry_rows() {
  local n d
  grep -av '^#' "$(ext_core_file)" | tr -d '\r' || true
  while IFS= read -r n; do
    d=$(ext_package_dir "$n") || continue
    [ -f "$d/commands.tsv" ] || continue
    ext_package_on "$n" || continue
    _ext_filter "$n" "$d" 0
  done < <(ext_package_names)
}

registry_rows_of() {   # registry_rows_of <name>
  local d
  d=$(ext_package_dir "$1") || return 1
  _ext_filter "$1" "$d" 0
}

registry_refused() {   # registry_refused [<name>]
  local n d
  while IFS= read -r n; do
    [ -z "${1:-}" ] || [ "$1" = "$n" ] || continue
    d=$(ext_package_dir "$n") || continue
    _ext_filter "$n" "$d" 1 | awk -F'\t' -v OFS='\t' -v n="$n" '{ print n, $2, $3, $4 }'
  done < <(ext_package_names)
}
