# shellcheck shell=bash
# The dump descriptor of a container: the one standard way an app's database is made safe to copy.
# File: $STATE/backup-dump/<container> (STATE = /var/lib/hs). One command per line, run INSIDE the container
# (sh -c) right before its files are backed up by `hs backup now`. Blank lines and lines starting with # are
# ignored; a line "# dump:<name>" is the marker of the command below it, so a recipe run again replaces its own
# command instead of adding a second one (a descriptor with a single plain command, the old format, still works).
# The commands are mostly `hs-dump ...` (scripts/recipes/files/hs-dump, installed in the container by
# install_dump_tool in recipes/_lib.sh); dumps land in /var/backups/hs/<name>/ in the container.

dump_cmds() {   # dump_cmds <descriptor file>: the commands, one per line
  [ -s "$1" ] || return 0
  grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" || true
}

dump_declare() {   # dump_declare <descriptor file> <name> <command>: add or replace the command called <name>
  local f=$1 name=$2 cmd=$3 tmp
  [ -n "$name" ] && [ -n "$cmd" ] || return 1
  case "$name$cmd" in *$'\n'*) return 1 ;; esac
  mkdir -p "$(dirname "$f")"
  tmp=$f.new
  { [ ! -s "$f" ] || awk -v m="# dump:$name" '
      skip { skip = 0; next }
      $0 == m { skip = 1; next }
      { print }' "$f"
    printf '# dump:%s\n%s\n' "$name" "$cmd"; } > "$tmp" && mv "$tmp" "$f"
}

dump_remove() {   # dump_remove <descriptor file> <name>
  local f=$1 tmp
  [ -s "$f" ] || return 0
  tmp=$f.new
  awk -v m="# dump:$2" 'skip { skip = 0; next } $0 == m { skip = 1; next } { print }' "$f" > "$tmp" && mv "$tmp" "$f"
  [ -s "$f" ] || rm -f "$f"
}
