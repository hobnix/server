#!/usr/bin/env bash
# scripts/iso.sh and scripts/iso-change.sh (issue #259): the ISO library. Stand-in curl and incus, a throwaway library folder, the job
# worker (apply-add) run directly: no root, no network, no Incus. The systemd job itself is hs_job's (tests/hs-job.sh).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test HS_STATE_DIR=$WORK/state HS_JOBS_DIR=$WORK/jobs HS_ISO_DIR=$WORK/lib HS_ISO_POLL=0.1
mkdir -p "$WORK/src" "$WORK/state"

# a small ISO 9660 look-alike (the signature CD001 at byte 32769) and a file that is none
python3 - "$WORK/src" <<'PY'
import sys
d = sys.argv[1]
b = bytearray(40000); b[32769:32774] = b'CD001'
open(d + '/debian.iso', 'wb').write(b)
open(d + '/notiso.iso', 'wb').write(b'x' * 40000)
PY
SUM=$(sha256sum "$WORK/src/debian.iso" | awk '{ print $1 }')
SUM512=$(sha512sum "$WORK/src/debian.iso" | awk '{ print $1 }')
BAD=$(printf '0%.0s' $(seq 64))

# stand-in curl: -I prints a Content-Length, a download copies the fixture (HS_FAKE_SLOW: stays a while so a stop can be tried)
cat > "$WORK/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$HS_FAKE_LOG"
out="" ; head=false ; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; --) url=$2; shift 2 ;; -*I*) head=true; shift ;; *) shift ;; esac
done
if $head; then printf 'HTTP/1.1 200 OK\r\nContent-Length: 40000\r\n\r\n'; exit 0; fi
case "$url" in *missing*) exit 22 ;; *notiso*) cp "$HS_FAKE_SRC/notiso.iso" "$out" ;; *)
  head -c 20000 "$HS_FAKE_SRC/debian.iso" > "$out"; [ -z "${HS_FAKE_SLOW:-}" ] || sleep "$HS_FAKE_SLOW"
  cp "$HS_FAKE_SRC/debian.iso" "$out" ;; esac
FAKE
# stand-in incus: one VM has debian.iso attached
cat > "$WORK/incus" <<'FAKE'
#!/usr/bin/env bash
cat <<JSON
[{"name":"vm1","type":"virtual-machine","devices":{"root":{"type":"disk","pool":"default","path":"/"},"iso":{"type":"disk","source":"$HS_ISO_DIR/used.iso"}}}]
JSON
FAKE
chmod +x "$WORK/curl" "$WORK/incus"
export HS_CURL=$WORK/curl HS_INCUS=$WORK/incus HS_FAKE_LOG=$WORK/curl.log HS_FAKE_SRC=$WORK/src
if ! command -v jq >/dev/null 2>&1; then skip "jq is not installed: iso tests not run"; finish; exit $?; fi
C="bash $SCRIPTS/iso-change.sh"

echo "-- plan: the checksum is mandatory, or explicitly not given"
out=$($C plan add "$WORK/src/debian.iso") && rc=0 || rc=$?
check_eq "no checksum: status needs, exit 2" $'status\tneeds\nneeds\tchecksum 2' "$out $rc"
out=$($C plan add "$WORK/src/debian.iso" --checksum "$SUM") || true
check_out "a SHA-256 is accepted, the plan says what is verified" "verify the sha256 checksum" echo "$out"
check_out "a SHA-512 is accepted" "verify the sha512" $C plan add "$WORK/src/debian.iso" --checksum "sha512:$SUM512"
check_out "a checksum of the wrong length is refused" "has 10 characters" $C plan add "$WORK/src/debian.iso" --checksum abcdef0123
check_out "both --checksum and --no-checksum is refused" "not both" $C plan add "$WORK/src/debian.iso" --checksum "$SUM" --no-checksum
check_out "--no-checksum warns that nothing is verified" "^warn.No checksum was given" $C plan add "$WORK/src/debian.iso" --no-checksum

echo "-- plan: what is refused"
check_out "a relative path" "absolute path" $C plan add debian.iso --no-checksum
check_out "a path with .." "no \"..\"" $C plan add "$WORK/src/../src/debian.iso" --no-checksum
check_out "a missing file" "There is no file" $C plan add "$WORK/src/none.iso" --no-checksum
check_out "a name that does not end in .iso" "not a usable image name" $C plan add "$WORK/src/debian.iso" --name x.img --no-checksum
check_out "ftp is not a URL we take" "absolute path of a file" $C plan add ftp://example.org/a.iso --no-checksum
check_out "a user name in the URL" "invalid URL" $C plan add https://user:pw@example.org/a.iso --no-checksum
check_out "the server itself" "does not download from itself" $C plan add http://127.0.0.1/a.iso --no-checksum
for h in 2130706433 0x7f.1 0177.0.0.1 127.1 0 0.0.0.0 127.000.000.001 localhost.; do
  check_out "loopback written as $h" "does not download from itself|write an IP address" $C plan add "http://$h/a.iso" --no-checksum
done
check_out "a LAN mirror by its address is fine" "^status.ok" $C plan add http://10.0.0.5/a.iso --no-checksum
check_out "a plain HTTP URL shows a warning" "^warn.This is a plain HTTP address" $C plan add http://example.org/debian-13.iso --checksum "$SUM"
out=$($C plan add https://example.org/debian-13.iso --checksum "$SUM")
check_eq "an HTTPS URL has no HTTP warning" "0" "$(grep -c 'plain HTTP' <<<"$out")"
check_out "the download is shown as long work" "^long.yes" echo "$out"

echo "-- the job: a local file with the right checksum"
$C apply-add --src "$WORK/src/debian.iso" --name debian.iso --algo sha256 --expect "$SUM" >"$WORK/log" 2>&1; rc=$?
check_eq "it succeeds" 0 "$rc"
check "the image is in the library" test -f "$WORK/lib/debian.iso"
check "no partial file is left" test ! -e "$WORK/lib/debian.iso.part"
row=$(bash "$SCRIPTS/iso.sh" --list)
check_eq "the list row: bytes, algorithm, checksum, checked, source, used by" "debian.iso	40000	sha256	$SUM	yes	$WORK/src/debian.iso	$(date +%F)	-" "$row"
check_out "adding the same name again is refused" "already" $C plan add "$WORK/src/debian.iso" --no-checksum
check_out "a file from the library itself is refused" "in the library already" $C plan add "$WORK/lib/debian.iso" --name other.iso --no-checksum

echo "-- the job: a wrong checksum deletes the file and shows both"
$C apply-add --src "$WORK/src/debian.iso" --name wrong.iso --algo sha256 --expect "$BAD" >"$WORK/log" 2>&1; rc=$?
check_eq "it fails" 1 "$rc"
check_out "the log shows the expected and the computed checksum" "expected .sha256.: $BAD" cat "$WORK/log"
check_out "...and the computed one" "computed .sha256.: $SUM" cat "$WORK/log"
check "nothing is left in the library" test ! -e "$WORK/lib/wrong.iso" -a ! -e "$WORK/lib/wrong.iso.part"

echo "-- the job: no checksum given shows the computed one"
$C apply-add --src "$WORK/src/debian.iso" --name nosum.iso --no-checksum >"$WORK/log" 2>&1
check_out "the computed SHA-256 is printed" "computed sha256 is: $SUM" cat "$WORK/log"
check_eq "the list says it was not checked" "no" "$(bash "$SCRIPTS/iso.sh" --list | awk -F'\t' '$1 == "nosum.iso" { print $5 }')"

echo "-- the job: not an ISO"
$C apply-add --src "$WORK/src/notiso.iso" --name notiso.iso --no-checksum >"$WORK/log" 2>&1; rc=$?
check_eq "it fails" 1 "$rc"
check_out "it says why" "not an ISO image" cat "$WORK/log"
check "the file is deleted" test ! -e "$WORK/lib/notiso.iso" -a ! -e "$WORK/lib/notiso.iso.part"

echo "-- the job: a URL"
$C apply-add --src https://example.org/debian-13.iso --name url.iso --algo sha512 --expect "$SUM512" >"$WORK/log" 2>&1; rc=$?
check_eq "a download with a SHA-512 works" 0 "$rc"
check_out "curl was told to allow only http and https and to fail on errors" "proto =http,https --proto-redir =http,https --max-redirs" cat "$WORK/curl.log"
check_out "the HTTP warning is in the log of a plain HTTP job" "plain HTTP" bash -c "$C apply-add --src http://example.org/h.iso --name h.iso --no-checksum 2>&1"
$C apply-add --src https://example.org/missing.iso --name gone.iso --no-checksum >"$WORK/log" 2>&1; rc=$?
check_eq "a failed download fails the job" 1 "$rc"
check "...and leaves nothing" test ! -e "$WORK/lib/gone.iso.part"

echo "-- stopping a download removes the partial file"
HS_FAKE_SLOW=30 $C apply-add --src https://example.org/slow.iso --name slow.iso --no-checksum >"$WORK/log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do [ -e "$WORK/lib/slow.iso.part" ] && break; sleep 0.1; done
check "the partial file exists while it runs" test -e "$WORK/lib/slow.iso.part"
kill -TERM "$pid"; wait "$pid" 2>/dev/null
check "the partial file is gone after the stop" test ! -e "$WORK/lib/slow.iso.part"
check "no image was added" test ! -e "$WORK/lib/slow.iso"

echo "-- remove"
touch "$WORK/lib/used.iso"
check_out "an image that an instance has attached is refused" "attached to vm1" $C plan remove used.iso
check_out "the plan of a removal is red and asks for the name" "^confirm_name.debian.iso" $C plan remove debian.iso
check_out "start without the name typed is refused" "type the name to confirm" $C start remove debian.iso
check_out "a name that is no image" "invalid image name" $C plan remove ../etc/passwd
$C start remove debian.iso --confirm debian.iso >/dev/null
check "the image and its record are gone" test ! -e "$WORK/lib/debian.iso" -a ! -e "$WORK/lib/debian.iso.meta"

echo "-- the library folder follows the setting"
unset HS_ISO_DIR
mkdir -p "$WORK/settings"; echo /srv/isos > "$WORK/settings/isoDir"
check_eq "isoDir is read" "/srv/isos" "$(HS_SETTINGS_DIR=$WORK/settings bash "$SCRIPTS/iso.sh" --dir)"
check_eq "the default" "/var/lib/hs/iso" "$(HS_SETTINGS_DIR=$WORK/none bash "$SCRIPTS/iso.sh" --dir)"
finish
