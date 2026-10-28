#!/usr/bin/env bash
# scripts/lib/ui.sh `table`: plain output is `column -t` as before; with gum it is indented by 2, the header gets a rule, the
# first column and a status in the last column are coloured, and the text itself stays aligned. No terminal needed.
set -uo pipefail
if ! command -v column >/dev/null 2>&1; then echo "skip  needs column (util-linux/bsdextrautils)"; [ -n "${REQUIRE_ALL:-}" ] && exit 1; exit 77; fi
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1 (got: $3 | want: $2)"; fail=1; fi; }
data=$'JOB\tWHAT\tRESULT\nhs-backup.service\tBack up shares (hs backup)\tok\nhs-sync.service\tPublish folders\tfailed\nhs-scrub.service\tVerify data\tnever'

plain=$(HS_PLAIN=1 bash -c ". '$here/scripts/lib/ui.sh'; table" <<<"$data")
check "plain is column -t" "$(column -t -s $'\t' <<<"$data")" "$plain"

gum=$(bash -c ". '$here/scripts/lib/ui.sh'; ui=gum; table" <<<"$data")
bare=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$gum")
check "every line is indented by 2" "0" "$(grep -vc '^  ' <<<"$bare")"
check "the header is followed by a rule" "yes" "$(l=$(sed -n 2p <<<"$bare"); [ -n "${l// /}" ] && ! grep -q '[A-Za-z0-9]' <<<"$l" && echo yes || echo no)"
check "the text stays aligned like column -t" "$(column -t -s $'\t' -o '  ' <<<"$data" | sed 's/[[:space:]]*$//' | sed 's/^/  /' | sed '1a\
RULE')" "$(sed '2s/.*/RULE/' <<<"$bare")"
red=$'\033[38;2;243;139;168m'; green=$'\033[38;2;166;227;161m'
check "failed is red" "1" "$(grep -cF "${red}failed" <<<"$gum")"
check "ok is green" "1" "$(grep -cF "${green}ok" <<<"$gum")"
exit $fail
