#!/usr/bin/env bash
# hs help --search: full text search in the registry and in docs/*.md. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_COMPLETE_DIR=$WORK/complete
HS="bash $SCRIPTS/lib/hs.sh"

echo "-- commands"
check_out "finds a command by its help text" "^  hs ssh-key add" $HS help --search "one more SSH key"
check_out "case does not matter" "^  hs ssh-key add" $HS help --search "ONE MORE ssh KEY"
check_out "finds by path" "^  hs share <share> rename" $HS help --search "share <share> rename"
check_out "the group heading" "^commands:" $HS help --search ssh-key
check_out "German help text in German" "^  hs ssh-key list" env HS_LANG=de $HS help --search "Fingerabdruck"
check_eq "the other language is not searched" "0" "$($HS help --search Fingerabdruck | grep -c '^  hs ssh-key list' || true)"

echo "-- guides"
fakeroot=$WORK/root; mkdir -p "$fakeroot/docs"
cp -r "$SCRIPTS" "$fakeroot/scripts"
printf '# Titel\n\nDer Schnappschuss kommt jede Nacht.\nZweite [Zeile] mit Klammer.\n' > "$fakeroot/docs/Eins.md"
printf 'nichts\nSCHNAPPSCHUSS gross\n' > "$fakeroot/docs/Zwei mit Leerzeichen.md"
H="bash $fakeroot/scripts/lib/hs.sh"
check_out "file, line and context" "^  docs/Eins.md:3: Der Schnappschuss kommt jede Nacht" $H help --search schnappschuss
check_out "a name with spaces" "^  docs/Zwei mit Leerzeichen.md:2: SCHNAPPSCHUSS gross" $H help --search schnappschuss
check_out "special characters are plain text" "^  docs/Eins.md:4: Zweite \[Zeile\]" $H help --search "[Zeile]"
check_out "several words are one phrase" "Eins.md:3" $H help --search "kommt jede"
check_out "nothing found says so" "Nothing found for: gibtesnicht" $H help --search gibtesnicht
check_eq "and fails" "1" "$($H help --search gibtesnicht >/dev/null 2>&1; echo $?)"
for i in $(seq 1 40); do echo "viel treffer $i" >> "$fakeroot/docs/Eins.md"; done
check_eq "at most 30 hits are printed" "30" "$($H help --search "viel treffer" | grep -c '^  docs/')"
check_out "and it says there are more" "more matches" $H help --search "viel treffer"
check_out "no word: usage" "usage: hs help --search" $H help --search

finish
