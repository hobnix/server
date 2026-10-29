#!/usr/bin/env bash
# scripts/lib/ui.sh `ask` with gum: gum input panics when the prompt leaves no room for the placeholder (a long recipe question on a narrow
# terminal), so a long question is printed on lines of its own and gum gets a short prompt. A stand-in `gum` records the --prompt it is given.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
printf '#!/usr/bin/env bash\nwhile [ $# -gt 0 ]; do [ "$1" = --prompt ] && printf "%%s" "$2" > "%s/prompt"; shift; done\n' "$T" > "$T/bin/gum"
chmod +x "$T/bin/gum"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }
run() { env COLUMNS=80 PATH="$T/bin:$PATH" bash -c ". '$here/scripts/lib/ui.sh'; ui=gum; ask \"\$1\" no" _ "$1" 2>"$T/err" >/dev/null; cat "$T/prompt"; }

check "a short question stays in the prompt" "Install it? (no): " "$(run 'Install it?')"
long='Delete the lower-resolution file when a film has two (say 4K and FullHD) in its folder, after a grace period? yes or no'
check "a long question gets a short prompt" "> " "$(run "$long")"
check "the long question is printed on its own lines" "yes" "$(grep -q 'grace period' "$T/err" && echo yes || echo no)"
exit $fail
