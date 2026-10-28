#!/usr/bin/env bash
# scripts/lib/ui.sh `steps N` / `step`: with gum the headings are a tree (├ first and middle, └ last), a script that
# does not declare its steps keeps ▸, the plain form is unchanged. A stand-in `gum` echoes the text it is told to style.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
printf '#!/usr/bin/env bash\n[ "$1" = style ] && { eval "echo \\"\${$#}\\""; exit 0; }\nexit 0\n' > "$T/bin/gum"
chmod +x "$T/bin/gum"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }
run() { env -u HS_STEP_TOTAL -u HS_STEP_N PATH="$T/bin:$PATH" bash -c ". '$here/scripts/lib/ui.sh'; ui=gum; $1" 2>&1 | grep -v '^$'; }

check "three steps: ├ ├ └" "├ One|├ Two|└ Three" "$(run 'steps 3; step One; step Two; step Three' | paste -sd'|')"
check "one step is the last one: └" "└ Only" "$(run 'steps 1; step Only')"
check "undeclared steps keep the old ▸" "▸ A|▸ B" "$(run 'step A; step B' | paste -sd'|')"
check "the count continues in a child process (exec)" "├ First|└ Second" "$(run 'steps 2; step First; bash -c ". '"$here"'/scripts/lib/ui.sh; ui=gum; step Second"' | paste -sd'|')"
check "plain stays ── Title ──" "── One ──" "$(HS_PLAIN=1 bash -c ". '$here/scripts/lib/ui.sh'; steps 2; step One" | grep -v '^$')"
exit $fail
