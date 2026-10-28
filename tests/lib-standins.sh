# shellcheck shell=bash
# Stand-ins for net, sharesec, wbinfo, zfs, incus, smbcontrol and flock, for the tests of manage-shares.sh and
# create-share.sh (sourced after tests/lib.sh). Every call is appended to $LOG. No root needed.
BIN=$WORK/bin; mkdir -p "$BIN"
LOG=$WORK/calls.log; : > "$LOG"; export LOG
for c in net sharesec wbinfo zfs incus smbcontrol flock; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$LOG"\nsource "%s/stub-%s.sh"\n' "$c" "$BIN" "$c" > "$BIN/$c"
  chmod +x "$BIN/$c"
done
cat > "$BIN/stub-net.sh" <<'FAKE'
case "$*" in
  "conf listshares") printf 'docs\nmedia\n' ;;
  "conf getparm docs path") echo /bulk/shares/docs ;;
  "conf getparm media path") echo /bulk/sensitive/media ;;
  "conf showshare docs") printf '[docs]\n\tpath = /bulk/shares/docs\n\tread only = no\n' ;;
  "conf showshare media") printf '[media]\n\tpath = /bulk/sensitive/media\n\tread only = yes\n' ;;
  "conf showshare"*) exit 1 ;;
  "conf getparm"*) exit 1 ;;
esac
FAKE
cat > "$BIN/stub-sharesec.sh" <<'FAKE'
case "$*" in
  "docs --view") printf 'ACL:S-1-1-0:ALLOWED/0x0/READ\nACL:S-1-5-21-1-1000:ALLOWED/0x0/CHANGE\nACL:S-1-5-21-1-512:ALLOWED/0x0/FULL\nACL:S-1-5-21-1-2000:DENIED/0x0/FULL\n' ;;
  "media --view") printf 'ACL:S-1-5-21-1-512:ALLOWED/0x0/0x001f01ff\n' ;;
esac
FAKE
cat > "$BIN/stub-wbinfo.sh" <<'FAKE'
case "$1" in
  -s) case "$2" in S-1-5-21-1-1000) echo 'HOME\anna 1' ;; S-1-5-21-1-512) echo 'HOME\Domain Admins 2' ;; *) exit 1 ;; esac ;;
  -g) printf 'Domain Admins\nStaff\nRODC Group\n' ;;
  -u) printf 'HOME\\anna\nHOME\\guest\n' ;;
  -n) case "$2" in "Domain Admins"|*Admins) echo 'S-1-5-21-1-512 2' ;; Staff) echo 'S-1-5-21-1-513 2' ;; *anna) echo 'S-1-5-21-1-1000 1' ;; *) exit 1 ;; esac ;;
esac
FAKE
cat > "$BIN/stub-zfs.sh" <<'FAKE'
case "$*" in
  "list -Hp -o used bulk/shares/docs") echo 1234 ;;
  "list -Hp -o used bulk/sensitive/media") echo 99 ;;
  "list -H -o name bulk/shares/docs"|"list -H -o name bulk/sensitive/media") ;;
  "list -H -o name"*) exit 1 ;;
  "create"*|"rename"*) ;;
  *) exit 1 ;;
esac
FAKE
cat > "$BIN/stub-incus.sh" <<'FAKE'
case "$1" in
  list) ;;                                   # no instances
  info) [ "$2" = web ] || exit 1 ;;
  config) case "$2" in get) ;; device) [ "$3" != get ] || exit 1 ;; esac ;;
esac
FAKE
: > "$BIN/stub-smbcontrol.sh"; : > "$BIN/stub-flock.sh"
export PATH="$BIN:$PATH"
