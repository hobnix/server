#!/usr/bin/env bash
# The plain output of manage-pool.sh (plans, dry runs): the interface parses it, so it must not change when the
# plans get their gum look (docs/CLI-DESIGN.md). Each scenario runs the script against fake zpool, lsblk, df ...
# (tests/lib-poolfakes.sh, no root, no disks) and compares the output byte for byte with tests/pool-look/<name>.out,
# which was recorded from the script BEFORE the restyling. Also checks that the gum look only appears with gum.
# Re-record (only when the text of a plan is changed on purpose, and then the interface's parser too):
#   HS_LOOK_RECORD=1 bash tests/pool-look.sh
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
GOLD=$ROOT/tests/pool-look
export HS_PLAIN=1 HS_LANG=en HS_STATE_DIR=$WORK/state
unset HS_CALLER HS_GUIDED_TTY
# shellcheck source=tests/lib-poolfakes.sh
. "$(dirname "$0")/lib-poolfakes.sh"

scenario() {   # scenario <name> <layout> <zpool scenario> <args...>: the plain output equals the recorded one
  local name=$1; shift
  local out; out=$(run "$@")
  if [ -n "${HS_LOOK_RECORD:-}" ]; then printf '%s\n' "$out" > "$GOLD/$name.out"; pass "recorded $name"; return; fi
  if diff <(printf '%s\n' "$out") "$GOLD/$name.out" >/dev/null; then pass "plain output unchanged: $name"
  else fail "plain output of $name differs"; diff <(printf '%s\n' "$out") "$GOLD/$name.out" | head -n 12; fi
}
mkdir -p "$GOLD"

echo "-- ZFS plans"
scenario zfs-replace   zfs two   bulk --replace ata-A --disks ata-FAKE_sdy --dry-run
scenario zfs-detach2   zfs one   bulk --remove ata-A --mode detach --dry-run
scenario zfs-detach3   zfs three bulk --remove ata-C --dry-run
scenario zfs-vdev      zfs two   bulk --remove ata-A --mode vdev --dry-run
scenario zfs-add       zfs two   bulk --disks ata-FAKE_sdy,ata-FAKE_sdz --dry-run
scenario zfs-create    zfs new   fast --disks ata-FAKE_sdy,ata-FAKE_sdz --dry-run

echo "-- SnapRAID plans"
scenario sr-add-data     snapraid one bulk --role data --disks ata-FAKE_sdy --dry-run
scenario sr-add-parity   snapraid one bulk --role parity --disks ata-FAKE_sdz --dry-run
scenario sr-replace-data snapraid one bulk --replace data-02 --disks ata-FAKE_sdy --dry-run
scenario sr-replace-par  snapraid one bulk --replace parity-1 --disks ata-FAKE_sdy --dry-run
scenario sr-remove-data  snapraid one bulk --remove data-02 --dry-run
scenario sr-remove-nomove snapraid one bulk --remove data-02 --mode nomove --dry-run
scenario sr-remove-par   snapraid one bulk --remove parity-1 --dry-run
printf 'bulk-data-01\n' > "$WORK/labels"; printf 'bulk-data-01 4000000000\n' > "$WORK/labels.size"
scenario sr-add-noparity snapraid one bulk --role data --disks ata-FAKE_sdy --dry-run
printf 'bulk-data-01\nbulk-data-02\nbulk-parity-1\n' > "$WORK/labels"
printf 'bulk-data-01 4000000000\nbulk-data-02 4000000000\nbulk-parity-1 4000000000\n' > "$WORK/labels.size"
scenario sr-convert      snapraid one bulk --convert data-02 --fs xfs --dry-run

echo "-- the next data label fills a gap, unless that name still waits to be dropped from the parity"
printf 'bulk-data-01\nbulk-data-03\nbulk-parity-1\n' > "$WORK/labels"
printf 'bulk-data-01 4000000000\nbulk-data-03 4000000000\nbulk-parity-1 4000000000\n' > "$WORK/labels.size"
out=$(run snapraid one bulk --role data --disks ata-FAKE_sdy --dry-run)
check_out "a gap (data-02) is used again" "label data-02|data-02" echo "$out"
printf 'data-02\n' > "$WORK/removals"
out=$(HS_REMOVALS_FILE=$WORK/removals run snapraid one bulk --role data --disks ata-FAKE_sdy --dry-run)
if grep -q 'data-02' <<<"$out"; then fail "a removal that is not synced yet must keep its name: $out"; else pass "a pending removal keeps its name; the next number is used"; fi
check_out "data-04 instead" "data-04" echo "$out"
printf 'bulk-data-01\nbulk-data-03\n' > "$WORK/labels"
printf 'bulk-data-01 4000000000\nbulk-data-03 4000000000\n' > "$WORK/labels.size"
printf 'data-02\n' > "$WORK/removals"
out=$(HS_REMOVALS_FILE=$WORK/removals run snapraid one bulk --role data --disks ata-FAKE_sdy --dry-run)
check_out "no parity disk: a left-over removal record does not block data-02" "data-02" echo "$out"
rm -f "$WORK/removals"
printf 'bulk-data-01\nbulk-data-02\nbulk-parity-1\n' > "$WORK/labels"
printf 'bulk-data-01 4000000000\nbulk-data-02 4000000000\nbulk-parity-1 4000000000\n' > "$WORK/labels.size"

echo "-- the gum look appears only with gum (never in plain mode, a pipe or for the interface)"
for sc in zfs-replace sr-replace-data; do
  check_out "$sc: the recorded plain output starts a plan with Plan:" "^Plan: " grep -h "^Plan: " "$GOLD/$sc.out"
  if grep -q '▸' "$GOLD/$sc.out"; then fail "$sc golden has a gum heading"; else pass "$sc golden has no gum heading"; fi
done
fake_gum=$WORK/gumbin; mkdir -p "$fake_gum"
cat > "$fake_gum/gum" <<'FAKE'
#!/usr/bin/env bash
# gum style: print the text (the colours do not matter here)
[ "$1" = style ] || exit 0
shift
while [ $# -gt 0 ]; do case "$1" in --bold) shift ;; --*) shift 2 ;; *) printf '%s\n' "$*"; break ;; esac; done
FAKE
chmod +x "$fake_gum/gum"
# ui=gum needs a terminal and the gum program: a copy of the scripts with the test in lib/ui.sh forced
cp -r "$SCRIPTS" "$WORK/gumscripts"
sed -i 's/^if \[ -t 1 \] && \[ -z "\${HS_PLAIN:-}" \] && command -v gum.*then ui=gum; fi$/ui=gum/' "$WORK/gumscripts/lib/ui.sh"
if ! grep -q '^ui=gum$' "$WORK/gumscripts/lib/ui.sh"; then fail "could not force ui=gum in the copy (lib/ui.sh changed?)"; else
  g() { PATH="$fake_gum:$PATH" bash "$WORK/gumscripts/manage-pool.sh" "$@" 2>&1 </dev/null | sed -E "s/$(printf '\033')\[[0-9;]*m//g"; }
  echo zfs > "$BT"; echo two > "$SCEN"
  out=$(g bulk --replace ata-A --disks ata-FAKE_sdy --dry-run)
  check_out "with gum the plan has a heading" "^(▸|├|└) replace ata-A" echo "$out"
  check_out "with gum the command is a fact" "^ +Command +zpool replace bulk" echo "$out"
  check_out "with gum the danger line stays" "ALL DATA on ata-FAKE_sdy will be erased" echo "$out"
  check_out "with gum the dry run closes with a mark" "✓ Dry run: nothing changed" echo "$out"
  if grep -q '^Plan: ' <<<"$out"; then fail "with gum the Plan: prefix is gone"; else pass "with gum the Plan: prefix is gone (heading instead)"; fi
  echo snapraid > "$BT"
  out=$(g bulk --replace data-02 --disks ata-FAKE_sdy --dry-run)
  check_out "with gum the steps are indented numbered lines" "^ +1\. take the old disk out" echo "$out"
  check_out "with gum the current array is a heading" "^(▸|├|└) Current array|^(▸|├|└) replace data-02" echo "$out"
fi

finish
