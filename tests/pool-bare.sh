#!/usr/bin/env bash
# The pool commands run bare (hs pool <pool> replace|remove|convert without a member): a person at a terminal is
# asked which disk, the same dialogue that the interface hands over to. Answers come from stdin (HS_GUIDED_TTY=1 =
# "there is a terminal", like the guided scripts); everything runs with --dry-run or stops at the typed
# confirmation, so no disk is touched. Also the order of the preparation questions (:
# encrypt?, filesystem, passphrase). Fake zpool/lsblk: tests/lib-poolfakes.sh. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_PLAIN=1 HS_LANG=en HS_STATE_DIR=$WORK/state
unset HS_CALLER
# shellcheck source=tests/lib-poolfakes.sh
. "$(dirname "$0")/lib-poolfakes.sh"
tty_() { HS_GUIDED_TTY=1 "$@"; }
ask() { local a=$1; shift; HS_ANSWERS=$a tty_ run "$@"; }   # ask <answers> <layout> <scenario> <args...>

echo "-- no terminal, no member: the usage line, as before"
check_out "--replace alone is refused" "usage: hs pool" run zfs two bulk --replace
check_out "--remove followed by an option is refused too" "usage: hs pool" run zfs two bulk --remove --dry-run
check_out "--convert alone is refused" "usage: hs pool" run snapraid one bulk --convert
check_out "a member given still works without a terminal" "Plan: take ata-A out of mirror-0" run zfs one bulk --remove ata-A --mode detach --dry-run

echo "-- ZFS: which disk"
out=$(ask '3\n' zfs two bulk --remove --mode detach --dry-run)
check_out "the disks are listed with state and group" "ata-A .*ONLINE.*mirror-0" echo "$out"
check_out "the third entry is picked" "Plan: take ata-D out of mirror-1" echo "$out"
out=$(ask '1\n1\n' zfs two bulk --replace --dry-run)
check_out "replace asks the member, then the free disk" "Plan: replace ata-A \(ONLINE, mirror-0\) in 'bulk' with ata-FAKE_sdy" echo "$out"
check_out "the free disks are listed" "ata-FAKE_sdz" echo "$out"
check_out "an option after --replace is still read" "with ata-FAKE_sdz" ask '2\n' zfs two bulk --replace --disks ata-FAKE_sdz --dry-run
check_out "a wrong answer cancels" "cancelled" ask 'x\n' zfs two bulk --remove --dry-run
check_out "convert has no meaning on ZFS: nothing to pick" "No data disk in 'bulk' can be converted" ask '1\n' zfs two bulk --convert
check_out "convert refuses a named ZFS member" "convert is for the data disks of the snapraid layout" run zfs two bulk --convert ata-A --dry-run

echo "-- SnapRAID: which disk"
out=$(ask '2\n' snapraid one bulk --convert --fs xfs --dry-run)
check_out "only data disks are offered for convert" "data-02" echo "$out"
if grep -q "parity-1" <<<"$out" && ! grep -q "Plan: convert" <<<"$out"; then fail "convert offers the parity disk"; else pass "convert offers no parity disk"; fi
check_out "the picked disk is converted" "Plan: convert the data disk data-02 in 'bulk' \(xfs\)" echo "$out"
check_out "remove offers the parity disk too" "parity-1 .*ONLINE" ask '3\n' snapraid one bulk --remove --dry-run
check_out "and takes it" "Plan: remove the parity disk parity-1" ask '3\n' snapraid one bulk --remove --dry-run
check_out "replace by menu" "Plan: replace data-01 \(ONLINE\) in 'bulk'" ask '1\n1\n' snapraid one bulk --replace --dry-run
check_out "the old way, member and disk given" "Plan: replace data-02" run snapraid one bulk --replace data-02 --disks ata-FAKE_sdy --dry-run

echo "-- the order of the questions: encrypt?, filesystem, passphrase (then the plan)"
# n = no: the filesystem follows
out=$(ask 'n\n2\nnope\n' snapraid one bulk --role data --disks ata-FAKE_sdy)
check_out "no encryption, xfs picked second" "as data-03 \(xfs\)" echo "$out"
check_out "the typed confirmation is asked after the plan" "cancelled" echo "$out"
# y = encrypt: filesystem, then the passphrase twice, then the plan
out=$(ask 'y\n3\nsecret\nsecret\nnope\n' snapraid one bulk --role data --disks ata-FAKE_sdy)
check_out "encryption yes, btrfs picked second" "as data-03 \(btrfs, encrypted \(LUKS\)\)" echo "$out"
out=$(ask 'y\nsecret\nsecret\nnope\n' zfs new fast --disks ata-FAKE_sdy,ata-FAKE_sdz)
check_out "a new ZFS pool: encryption is asked, then the passphrase" "encryption=aes-256-gcm" echo "$out"
out=$(ask 'n\nnope\n' zfs new fast --disks ata-FAKE_sdy,ata-FAKE_sdz)
if grep -q "encryption=" <<<"$out"; then fail "a new ZFS pool without encryption has encryption options"; else pass "a new ZFS pool without encryption"; fi
check_out "an existing ZFS pool is not asked" "Plan: add to the existing pool" ask 'nope\n' zfs two bulk --disks ata-FAKE_sdy,ata-FAKE_sdz

echo "-- bare hs pool <pool> only shows (adding is hs pool <pool> add)"
out=$(ask '' zfs two bulk --show)
check_out "it shows the pool" "Pool bulk" echo "$out"
check_out "with the state" "state" echo "$out"
check_out "and the disks in a table" "ata-A .*ONLINE" echo "$out"
check_out "and names the commands that change it" "hs pool bulk add" echo "$out"
if grep -qi "cancelled\|Add disks\|--disks" <<<"$out"; then fail "it asked or planned something"; else pass "it asked nothing and planned nothing"; fi
out=$(ask '' snapraid one bulk --show)
check_out "snapraid: the members" "data-01.*ONLINE" echo "$out"
check_out "snapraid: sync is named too" "sync" echo "$out"

echo "-- a pool with any name: a NEW name needs the pools line, a role and a good name"
export HS_MACHINE_FILE=$WORK/machine.toml
rm -f "$HS_MACHINE_FILE"
D=--disks\ ata-FAKE_sdy,ata-FAKE_sdz
check_out "legacy server: a new name asks for hs pool record first" "Run hs pool record first" run zfs new tank --use data $D --dry-run
check_out "legacy bulk is no new pool (plan as before)" "Plan: create the new pool 'bulk'" run zfs new bulk $D --dry-run
out=$(run zfs new bulk $D --dry-run)
if grep -q "NEW pool" <<<"$out"; then fail "legacy bulk is called a NEW pool"; else pass "legacy bulk: no NEW pool line"; fi
printf 'pools = { bulk = { role = "data", kind = "zfs" } }\n' >"$HS_MACHINE_FILE"
out=$(run zfs new tank --use data $D --dry-run)
check_out "new data pool: the plan says so" "a NEW pool 'tank' with role data" echo "$out"
if grep -q "mountpoint=none" <<<"$out"; then fail "a data pool has mountpoint=none"; else pass "a data pool is mounted at /tank"; fi
check_out "new apps pool: no mount point of its own" "mountpoint=none" run zfs new ssd --use apps $D --dry-run
check_out "a row that is not created yet is no NEW pool" "Plan: create the new pool 'bulk'" run zfs new bulk $D --dry-run
check_out "a bad name is refused" "invalid pool name" run zfs new mirror --use data $D --dry-run
check_out "a long name is refused" "invalid pool name" run zfs new abcdefghijklm --use data $D --dry-run
check_out "no --use, no terminal: the usage line" "usage: hs pool" run zfs new tank $D --dry-run
check_out "--use must be data or apps" "use: data or apps" run zfs new tank --use fast $D --dry-run
check_out "a snapraid request for another name is refused" "only the pool named bulk" run zfs new tank --use data --role data $D --dry-run
check_out "the menu offers the rows and a new pool" "new" ask '2\n' zfs new --use apps $D --dry-run
out=$(HS_ANSWERS='2\ntank\n' tty_ run zfs new --use data $D --dry-run)
check_out "the menu: a new pool asks the name" "a NEW pool 'tank' with role data" echo "$out"
out=$(HS_ANSWERS='1\n' tty_ run zfs new tank $D --dry-run)
check_out "a terminal is asked what the new pool is for" "a NEW pool 'tank' with role data" echo "$out"
rm -f "$HS_MACHINE_FILE"

finish
