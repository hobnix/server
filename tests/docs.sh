#!/usr/bin/env bash
# hs docs build: guides + package guides + generated command reference + index.json for the Docs page of the web interface. No root, no network.
# The guides are English and follow docs/GUIDE-TEMPLATE.md; this test checks the parts a machine can.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1
OUT=$WORK/site
B="bash $SCRIPTS/docs-build.sh --out $OUT"
REG=$SCRIPTS/lib/registry.tsv
DOCS=$ROOT/docs
py=python3; have python3 || py=python

echo "-- build"
check_out "it builds" "Documentation built" $B
for f in index.json en/start.md en/commands.md; do
  check "$f exists" test -s "$OUT/$f"
done
check "no German pages are written (the guides are English)" test ! -e "$OUT/de"
check "no Docsify files are written any more" test ! -e "$OUT/index.html" -a ! -e "$OUT/vendor" -a ! -e "$OUT/en/_sidebar.md"
check "the helper table of categories is not left behind" test ! -e "$OUT/_categories.tsv"

echo "-- every command is on the page"
missing=""
while IFS=$'\t' read -r kind path _ _ _ _ flags; do
  [ "$kind" = user ] || continue
  case ",${flags:-}," in *,nohelp,*) continue ;; esac
  grep -qF -- "\`hs $path" "$OUT/en/commands.md" || missing="$missing [$path]"
done < <(grep -v '^#' "$REG")
check_eq "the command page names every command" "" "$missing"
missing_sys=""
while IFS=$'\t' read -r kind path _; do
  [ "$kind" = sys ] || continue
  grep -qF -- "\`hs $path\`" "$OUT/en/commands.md" || missing_sys="$missing_sys [$path]"
done < <(grep -v '^#' "$REG")
check_eq "the system commands are listed" "" "$missing_sys"

echo "-- the text of the pages"
check_out "English help text is used" "create a share" cat "$OUT/en/commands.md"
check_eq "nothing is HTML-escaped (the renderer shows <tags> as they are)" "" "$(grep -lE '&(lt|gt|amp);' "$OUT/en/commands.md" || true)"
check_eq "no cell ends in a bare pipe inside code (an unescaped | would split the row)" "" "$(grep -E '^\| `hs ' "$OUT/en/commands.md" | sed 's/\\|//g' | awk -F'|' 'NF != 4 { print }' | head -n 3)"
check_eq "no '(none)' is printed as an argument" "" "$(grep -F '(none)' "$OUT/en/commands.md" | head -n 2)"
check_eq "the generated start page uses no raw HTML" "" "$(grep -lE '<(small|br|div|span|details)' "$OUT/en/start.md" || true)"

echo "-- the files of docs/"
unlisted=""
for f in "$DOCS"/*.md; do
  b=$(basename "$f" .md); [ "$b" = README ] && continue
  grep -qE "^en	[^	]+	$b\$" "$DOCS/categories.tsv" || unlisted="$unlisted [$b]"
  grep -qF "($b.md)" "$DOCS/README.md" || unlisted="$unlisted [README:$b]"
done
check_eq "every file of docs/ is in categories.tsv and docs/README.md" "" "$unlisted"
dangling=""
while IFS=$'\t' read -r lang group file; do
  case "$lang" in ""|\#*) continue ;; esac
  [ "$file" = @commands ] || [ -f "$DOCS/$file.md" ] || dangling="$dangling [$file]"
done < "$DOCS/categories.tsv"
check_eq "every row of categories.tsv names a file" "" "$dangling"
check_eq "file names of docs/ are plain (no space, no +)" "" "$(find "$DOCS" -maxdepth 1 -name '* *' -o -maxdepth 1 -name '*+*')"
check_eq "no page is empty" "" "$(find "$OUT" -name '*.md' -size -40c | head -n 3)"

echo "-- guides follow the template (docs/GUIDE-TEMPLATE.md)"
CORE="install containers-and-apps users-and-shares storage-and-disks encryption-and-vault backup-and-recovery web-interface operations"
bad=""
for g in $CORE; do
  f=$DOCS/$g.md
  [ -f "$f" ] || { bad="$bad [$g: missing]"; continue; }
  [ "$(grep -c '^# ' "$f")" = 1 ] || bad="$bad [$g: one H1]"
  grep -q '^## Before you start' "$f" || [ "$g" = install ] || bad="$bad [$g: Before you start]"
  grep -q '^## If something goes wrong' "$f" || bad="$bad [$g: If something goes wrong]"
  grep -q '^## Next' "$f" || bad="$bad [$g: Next]"
done
check_eq "the nine guides exist and have the template's sections" "" "$bad"
bad=""
for f in "$DOCS"/*.md "$ROOT"/packages/*/guide.md "$ROOT"/capabilities/*/guide.md; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in README.md|PLAN-*|Entwicklungsnotizen.md|CLI-DESIGN.md) continue ;; esac
  grep -qE '<(p|br|div|span|details|summary|img|a|table|b|i|small|center)[ >/]' "$f" && bad="$bad [html:$f]"
  grep -qE '^```bash$' "$f" && awk '/^```bash$/ { inb = 1; next } /^```/ { inb = 0 } inb && /^\$ / { print FILENAME; exit }' "$f" | grep -q . && bad="$bad [prompt:$f]"
  grep -qiE "\b(example\.com|192\.168\.1\.)" "$f" || true
done
check_eq "no raw HTML and no \$ prompt in a command block" "" "$bad"
bad=""
for f in "$ROOT"/packages/*/guide.md "$ROOT"/capabilities/*/guide.md; do
  [ -f "$f" ] || continue
  [ "$(grep -c '^# ' "$f")" = 1 ] || bad="$bad [one H1:$f]"
  [ "$(wc -l < "$f")" -le 220 ] || bad="$bad [too long:$f]"
done
check_eq "a package guide has one H1 and stays short" "" "$bad"
for f in "$ROOT"/packages/*/guide.md "$ROOT"/capabilities/*/guide.md; do
  [ -f "$f" ] || continue
  n=$(basename "$(dirname "$f")")
  check "the guide of the package $n is a page" test -s "$OUT/en/$n.md"
done

echo "-- index.json"
if have python3 || have python; then
  res=$($py -I - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
d = json.load(open(os.path.join(out, "index.json"), encoding="utf-8"))
bad = []
if set(d["langs"]) != {"en"}:
    bad.append("languages: %s" % sorted(d["langs"]))
info = d["langs"]["en"]
if not info["groups"]:
    bad.append("no groups")
if info["start"] != "start" or not os.path.isfile(os.path.join(out, "en", "start.md")):
    bad.append("start page")
names = [g["name"] for g in info["groups"]]
for g in info["groups"]:
    if g["name"] == "More":
        bad.append("a page is under More: " + ", ".join(p["slug"] for p in g["pages"]))
    for p in g["pages"]:
        if not os.path.isfile(os.path.join(out, "en", p["slug"] + ".md")):
            bad.append(p["slug"] + " has no file")
        if not p["title"]:
            bad.append(p["slug"] + " has no title")
pages = {p["slug"]: p for g in info["groups"] for p in g["pages"]}
if pages.get("commands", {}).get("title") != "All commands":
    bad.append("the command page title")
if pages.get("install", {}).get("file") != "install.md":
    bad.append("the file name is kept for links between guides")
for n in ("Guides", "Reference"):
    if n not in names:
        bad.append("group missing: " + n)
print("; ".join(bad))
PY
)
  check_eq "index.json: English only, groups, titles, no page under More" "" "$res"
else
  skip "python missing"
fi

echo "-- links in the generated start page point to pages"
bad=""
f=$OUT/en/start.md
while IFS= read -r l; do
  p=${l#*](}; p=${p%)}
  case "$p" in http*) continue ;; esac
  [ -s "$OUT/en/$p" ] || bad="$bad $p"
done < <(grep -o '\[[^]]*\]([^)]*)' "$f")
check_eq "every link of the start page points to a page" "" "$bad"
check "pages are world readable" test "$(stat -c %a "$OUT/index.json" | cut -c3)" -ge 4

echo "-- a second build replaces the first"
echo old > "$OUT/en/zzz-old.md"
$B --quiet >/dev/null
check "an old page is gone" test ! -e "$OUT/en/zzz-old.md"
check "the index is there again" test -s "$OUT/index.json"

echo "-- the links between guides resolve in the web interface (web/src/docs/docs.js)"
if have node; then
  if out=$(node "$ROOT/tests/web-docs-links.mjs" "$OUT" 2>&1); then pass "guide links resolve ($(grep -E '^  -> ' <<<"$out"))"; else fail "guide links: $(tail -n 12 <<<"$out")"; fi
else
  skip "node missing"
fi

finish
