#!/usr/bin/env bash
# hs backup drill ct: restore a container from restic into a throwaway Incus instance, boot it, delete it.
# A fake restic and a fake incus (HS_INCUS); no root, no real Incus. What the fakes cannot tell: whether a real
# Incus accepts the image and the id shift (see CLAUDE.md, "Container restore drill").
set -uo pipefail
. "$(dirname "$0")/lib.sh"

BIN=$WORK/bin; mkdir -p "$BIN"
export HS_STATE_DIR=$WORK/state HS_BACKUP_NO_MOUNT=1 HS_BACKUP_MOUNT=$WORK/mnt HS_BACKUP_CACHE=$WORK/cache HS_PLAIN=1
export HS_INCUS_ROOT=$WORK/incus HS_DRILL_TMP=$WORK/dtmp HS_DRILL_WAIT=4 HS_RUN_DIR=$WORK/run
export FAKEDIR=$WORK/fake LOG=$WORK/calls.log
mkdir -p "$HS_STATE_DIR" "$WORK/mnt/restic" "$FAKEDIR"
: > "$LOG"; : > "$FAKEDIR/instances"; : > "$FAKEDIR/images"
echo x > "$WORK/mnt/restic/config"; echo pw > "$HS_STATE_DIR/restic-password"
export PATH="$BIN:$PATH"

cat > "$BIN/restic" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = -r ] && shift 2; [ "$1" = --password-file ] && shift 2
cmd=$1; shift
echo "restic $cmd $*" >> "$LOG"
case "$cmd" in
  snapshots)
    printf '[{"id":"aaa0","time":"2026-09-01T00:00:00Z","tags":["ct:small"]},{"id":"aaa1","time":"2026-10-01T00:00:00Z","tags":["ct:big"]},{"id":"aaa2","time":"2026-10-02T00:00:00Z","tags":["ct:small"]},{"id":"hhh1","time":"2026-10-02T00:00:00Z","tags":["host"]}]\n' ;;
  stats)
    id=${!#}
    if [ -n "${FAKE_HUGE:-}" ]; then echo '{"total_size": 900000000000000000}'; exit 0; fi
    case "$id" in aaa1) echo '{"total_size": 900}' ;; aaa2) echo '{"total_size": 100}' ;; *) echo '{"total_size": 5}' ;; esac ;;
  restore)
    id=$1; shift; target=""; tag=""
    while [ $# -gt 0 ]; do case "$1" in --target) target=$2; shift 2 ;; --tag) tag=$2; shift 2 ;; --include) shift 2 ;; *) shift ;; esac; done
    [ -z "${FAKE_RESTORE_FAIL:-}" ] || exit 1
    case "$id" in
      aaa1|aaa2)
        name=small; [ "$id" = aaa1 ] && name=big
        root=$target$HS_INCUS_ROOT/$name/rootfs
        mkdir -p "$root/bin" "$root/var/lib"
        [ -n "${FAKE_NOETC:-}" ] || { mkdir -p "$root/etc"; echo "$name" > "$root/etc/hostname"; }
        echo data > "$root/var/lib/file" ;;
      latest)
        [ "$tag" = host ] || exit 1
        d=$target$HS_STATE_DIR/backup-dc; mkdir -p "$d" "$target/pk/private"
        if [ -n "${FAKE_DC_BAD:-}" ]; then echo nothing > "$target/pk/private/other.txt"; else echo ldb > "$target/pk/private/sam.ldb"; fi
        tar -cjf "$d/domain-backup.tar.bz2" -C "$target/pk" private ;;
    esac ;;
esac
FAKE
cat > "$BIN/incus" <<'FAKE'
#!/usr/bin/env bash
echo "incus $*" >> "$LOG"
case "$1" in
  list) cat "$FAKEDIR/instances" ;;
  info) [ "$2" != dc1 ] || [ -n "${FAKE_DC:-}" ]; exit $? ;;
  delete) sed -i "/^${3}\$/d" "$FAKEDIR/instances" ;;
  image)
    case "$2" in
      import) tar -tzf "$3" | grep -qx metadata.yaml && tar -tzf "$3" | grep -q '^rootfs/etc/hostname$' || exit 1
              tar -tzf "$3" | grep -q '^rootfs/proc' || exit 1
              echo "$5" >> "$FAKEDIR/images" ;;
      delete) grep -qx "$3" "$FAKEDIR/images" || exit 1; sed -i "/^${3}\$/d" "$FAKEDIR/images" ;;
    esac ;;
  init) case "$*" in *--no-profiles*) ;; *) exit 1 ;; esac
        case "$*" in *network*|*nic*) exit 1 ;; esac
        echo "$3" >> "$FAKEDIR/instances"; rm -f "$FAKEDIR/started" ;;
  config) ;;
  start) touch "$FAKEDIR/started" ;;
  exec)
    shift 2; [ "$1" = -- ] && shift
    case "$1" in
      true) [ -z "${FAKE_BOOT_FAIL:-}" ] || exit 1
            [ -z "${FAKE_HANG:-}" ] || { sleep 3; exit 1; }
            [ -f "$FAKEDIR/started" ] ;;
      systemctl) echo degraded ;;
    esac ;;
esac
exit 0
FAKE
chmod +x "$BIN/restic" "$BIN/incus"
export HS_INCUS=$BIN/incus
hsb() { bash "$SCRIPTS/backup.sh" "$@"; }
st() { sed -n "s/^$1=//p" "$HS_STATE_DIR/backup.state" 2>/dev/null | tail -n1; }
clean() { [ ! -s "$FAKEDIR/instances" ] && [ ! -s "$FAKEDIR/images" ] && [ -z "$(ls -A "$HS_DRILL_TMP" 2>/dev/null)" ]; }

echo "-- rotation: the smaller container first, then the other, then the oldest again"
check "first drill works" hsb drill ct
check_eq "the smaller one came first" small "$(st drill_ct_name)"
check "the throwaway instance, its image and the temp folder are gone" clean
check "the newest snapshot of the tag was restored (not the old one)" grep -q "^restic restore aaa2 " "$LOG"
check "the instance got no profiles (no network card)" grep -q "^incus init hs-drill-img-small hs-drill-small --no-profiles" "$LOG"
check "only a root disk was added" bash -c "grep '^incus config device add' $LOG | grep -vq ' root disk '; [ \$? -ne 0 ]"
check "the instance was started and run" grep -q "^incus exec hs-drill-small -- true" "$LOG"
check "ok time is recorded" test -n "$(st drill_ct_ok)"
check "no domain controller here: no dc state" test -z "$(st drill_dc_ok)"
check "second drill works" hsb drill ct
check_eq "the other one is next" big "$(st drill_ct_name)"
check "third drill works" hsb drill ct
check_eq "and then the longest ago again" small "$(st drill_ct_name)"
check_eq "three tries recorded" 3 "$(wc -l < "$HS_STATE_DIR/backup-drill-ct" | tr -d ' ')"

echo "-- a named container, an unknown one"
check "drill ct big" hsb drill ct big
check_eq "recorded" big "$(st drill_ct_name)"
check_out "an unknown container is an error" "No backup of a container called nope" hsb drill ct nope
check_eq "and exits 1" 1 "$(hsb drill ct nope >/dev/null 2>&1; echo $?)"
check "the plain file drill is still routed (numeric argument checked)" bash -c "! bash '$SCRIPTS/backup.sh' drill x"

echo "-- failures clean up and do not count"
before=$(st drill_ct_ok)
sleep 1
FAKE_BOOT_FAIL=1 hsb drill ct small >/dev/null 2>&1; rc=$?
check_eq "a container that does not boot fails the drill" 1 "$rc"
check "nothing is left behind" clean
check_eq "drill_ct_ok did not move" "$before" "$(st drill_ct_ok)"
check_eq "the try is recorded as failed" failed "$(tail -n1 "$HS_STATE_DIR/backup-drill-ct" | awk '{print $3}')"
check_eq "a restore that fails fails the drill" 1 "$(FAKE_RESTORE_FAIL=1 hsb drill ct small >/dev/null 2>&1; echo $?)"
check "and leaves nothing" clean
check_eq "a snapshot without a root file system fails" 1 "$(FAKE_NOETC=1 hsb drill ct small >/dev/null 2>&1; echo $?)"
check "and leaves nothing" clean
check_out "too little space is said" "needs about" env FAKE_HUGE=1 bash "$SCRIPTS/backup.sh" drill ct small
check "and leaves nothing" clean
echo "dc1" > "$FAKEDIR/instances"; echo "hs-drill-old" >> "$FAKEDIR/instances"
echo "hs-drill-img-small" >> "$FAKEDIR/images"
hsb drill ct small >/dev/null 2>&1
check "a leftover drill instance of a killed run is swept, other instances stay" bash -c "grep -qx dc1 '$FAKEDIR/instances' && ! grep -q hs-drill '$FAKEDIR/instances' && [ ! -s '$FAKEDIR/images' ]"
: > "$FAKEDIR/instances"

echo "-- termination (Ctrl-C / systemd stop) in the middle of the boot wait"
FAKE_HANG=1 bash "$SCRIPTS/backup.sh" drill ct small >/dev/null 2>&1 &
pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q "^incus exec hs-drill-small -- true" "$LOG" && break; sleep 0.3; done
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
check "instance, image and temp folder are removed" clean

echo "-- domain controller backup file"
FAKE_DC=1 hsb drill ct small >/dev/null 2>&1; rc=$?
check_eq "with a good domain backup the drill passes" 0 "$rc"
check "drill_dc_ok is recorded" test -n "$(st drill_dc_ok)"
check "temp folder removed" clean
ok_before=$(st drill_ct_ok); dc_before=$(st drill_dc_ok); sleep 1
FAKE_DC=1 FAKE_DC_BAD=1 hsb drill ct small >/dev/null 2>&1; rc=$?
check_eq "a domain backup without sam.ldb fails the drill" 1 "$rc"
check_eq "drill_dc_ok did not move" "$dc_before" "$(st drill_dc_ok)"
check "but the container part was still done" test "$(st drill_ct_ok)" != "$ok_before"
check "temp folder removed" clean
check_out "drill ct dc1 checks only the domain backup" "Domain backup" env FAKE_DC=1 bash "$SCRIPTS/backup.sh" drill ct dc1

echo "-- state and status"
out=$(hsb --state)
check_out "--state has the container drill" "^drill_ct_name	" echo "$out"
check_out "and the old keys are still there" "^drill_ok	" echo "$out"
check_out "status shows a line" "Container drill" hsb status

echo "-- the image: ids are unshifted, metadata and the folders the backup leaves out are there"
mkdir -p "$WORK/rf/etc"; echo h > "$WORK/rf/etc/hostname"
python3 "$SCRIPTS/lib/ct-image.py" build "$WORK/rf" "$WORK/img.tar.gz" web
check "metadata.yaml, the files, proc and var/tmp" bash -c "tar -tzf '$WORK/img.tar.gz' | sort | tr '\n' ' ' | grep -q 'metadata.yaml .*rootfs/etc/hostname .*rootfs/proc/ .*rootfs/var/tmp/'"
check_eq "a host id is brought back to the container's" 5 "$(python3 -c "import sys; exec(open(sys.argv[1]).read().split('if __name__')[0]); print(unshift(1000005, 1000000))" "$SCRIPTS/lib/ct-image.py")"
check_eq "an id outside the range is left alone" 7 "$(python3 -c "import sys; exec(open(sys.argv[1]).read().split('if __name__')[0]); print(unshift(7, 1000000))" "$SCRIPTS/lib/ct-image.py")"
check_eq "the newest snapshot per container" "big	aaa1
small	aaa2" "$(printf '[{"id":"a","time":"1","tags":["ct:small"]},{"id":"b","time":"2","tags":["ct:small"]},{"id":"c","time":"1","tags":["ct:big","x"]}]' | python3 "$SCRIPTS/lib/ct-image.py" newest | sed 's/\tb$/\taaa2/; s/\tc$/\taaa1/')"

finish
