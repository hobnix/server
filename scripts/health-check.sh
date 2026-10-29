#!/usr/bin/env bash
# help: check pools, disks, free space and scheduled jobs; push a message when something changes (also runs every 15 minutes)
# help.de: prüft Pools, Platten, freien Platz und geplante Aufgaben; schickt eine Nachricht, wenn sich etwas ändert (läuft auch alle 15 Minuten)
# args: [--test] [--dry-run]
# --keys (used by `hs update` to compare before and after a switch): only the key of every problem, one per line; sends and writes nothing. --list (used by `hs health ack` and the web Health page): key, text, acked or -, since (epoch seconds: the first run that saw the key, file health-since next to health-ack), channels that took the last message (notify.sh keeps them in the channel folder; comma separated or -), tab-separated. Columns are only ever added at the end.
set -euo pipefail

max_temp=55      # °C, at or above this a disk is reported
max_full=90      # %, at or above this a filesystem or pool is reported
scrub_days=21    # report a scrub older than this many days (both run weekly)
cert_days=30     # report the domain controller's certificate this many days before it expires
remind=86400     # seconds: unchanged problems are sent again once a day

here=$(dirname "$0")
. "$here/lib/ntfy.sh"
. "$here/lib/setting.sh"
. "$here/lib/dc.sh"
. "$here/lib/capacity.sh"
. "$here/lib/bulklock.sh"
. "$here/lib/capability.sh"
. "$here/lib/channels.sh"
state=${HS_HEALTH_STATE:-/var/lib/hs/health.state}   # override for tests
ack_file=${HS_ACK_FILE:-/var/lib/hs/health-ack}      # key TAB time: problems somebody acknowledged (hs health ack)
host=$(hostname)
now=${HS_NOW:-$(date +%s)}

test_msg=false
dry=false
keys_only=false
list_only=false
while [ $# -gt 0 ]; do
  case "$1" in
    --test)    test_msg=true; shift ;;
    --dry-run) dry=true; shift ;;
    --keys)    keys_only=true; dry=true; shift ;;   # the key of every problem, one per line (hs update); sends nothing
    --list)    list_only=true; dry=true; shift ;;   # key TAB text TAB acked|- per problem (hs health ack); sends nothing
    *) echo "usage: hs health [test]"; exit 1 ;;
  esac
done

# Every problem has a key and a text. The text is what people read; the key
# leaves out numbers that change all the time (degrees, percent, days), so a
# disk going from 56 to 57 °C doesn't count as a new problem.
keys=()
texts=()
problem() { keys+=("$1"); texts+=("$2"); }
have() { command -v "$1" >/dev/null 2>&1; }

# ── ZFS pools ──
if have zpool; then
  for p in $(zpool list -H -o name 2>/dev/null || true); do
    [[ "$(zpool status -x "$p" 2>/dev/null || true)" == *"is healthy"* ]] && continue
    health=$(zpool list -H -o health "$p" 2>/dev/null || echo unknown)
    problem "zfs:$p:$health" "ZFS pool $p is not healthy (state $health). Details: zpool status $p"
  done
  # Scrub: the weekly one must keep running and must not have found errors.
  # "scrub repaired 0B in 00:10:02 with 0 errors on Sun Oct  4 00:24:01 2026"
  for p in $(zpool list -H -o name 2>/dev/null || true); do
    scan=$(zpool status "$p" 2>/dev/null | sed -n 's/^ *scan: *//p' | head -n1 || true)
    if [[ "$scan" =~ with\ ([0-9]+)\ errors\ on\ (.+)$ ]]; then
      [ "${BASH_REMATCH[1]}" -eq 0 ] || problem "zfs:$p:scrub-errors" "the last scrub of ZFS pool $p found ${BASH_REMATCH[1]} error(s). Details: zpool status -v $p"
      when=$(date -d "${BASH_REMATCH[2]}" +%s 2>/dev/null || true)
      if [[ "$when" =~ ^[0-9]+$ ]] && [ $(( now - when )) -gt $(( scrub_days * 86400 )) ]; then
        problem "zfs:$p:scrub-old" "the last scrub of ZFS pool $p finished $(( (now - when) / 86400 )) days ago (weekly expected). Details: journalctl -u zfs-scrub"
      fi
    elif [[ "$scan" == *"scrub in progress"* ]]; then
      :
    else
      created=$(zpool get -Hp -o value creation "$p" 2>/dev/null || true)
      if [[ "$created" =~ ^[0-9]+$ ]] && [ $(( now - created )) -gt $(( scrub_days * 86400 )) ]; then
        problem "zfs:$p:scrub-never" "ZFS pool $p has never finished a scrub. Start one: zpool scrub $p"
      fi
    fi
  done
fi

# ── SnapRAID layout: every member mounted, and a parity disk at all ──
bulk_type=$(cat /etc/hs/bulk-type 2>/dev/null || echo zfs)
if [ "$bulk_type" = snapraid ]; then
  # name, bytes, state, group
  members=$(bash "$here/manage-pool.sh" bulk --members 2>/dev/null || true)
  while IFS=$'\t' read -r name _ mstate _; do
    [ -n "$name" ] || continue
    [ "$mstate" = ONLINE ] || problem "bulk:$name:$mstate" "bulk disk $name is $mstate. Replace it with: hs pool bulk replace"
  done <<<"$members"
  if [ -n "$members" ] && ! awk -F'\t' '$4 == "parity" { f = 1 } END { exit !f }' <<<"$members"; then
    problem "bulk:no-parity" "bulk has no parity disk: a failed disk loses its data"
  fi
fi

# SnapRAID: the weekly scrub (bulk-sync.sh --scrub writes the time of a finished one)
if [ "$bulk_type" = snapraid ] && [ -f /var/lib/snapraid/members ]; then
  scrub_ok=$(cat "${HS_SCRUB_STATE:-/var/lib/hs/scrub.state}" 2>/dev/null || true)
  if [[ "$scrub_ok" =~ ^[0-9]+$ ]]; then
    [ $(( now - scrub_ok )) -le $(( scrub_days * 86400 )) ] ||
      problem "bulk:scrub-old" "the last SnapRAID scrub finished $(( (now - scrub_ok) / 86400 )) days ago (weekly expected). Details: journalctl -u hs-bulk-scrub"
  elif [ -f /var/lib/snapraid/snapraid.content ] && [ $(( now - $(stat -c %Y /var/lib/snapraid/snapraid.content) )) -gt $(( 60 * 86400 )) ]; then
    problem "bulk:scrub-never" "no SnapRAID scrub has finished yet. Start one: hs pool bulk sync --scrub"
  fi
fi

# ── Disks: SMART verdict, pending sectors, temperature ──
# Without root smartctl reads nothing and every value is "-": nothing to report then.
while IFS=$'\t' read -r key text; do
  [ -n "$key" ] || continue
  problem "$key" "$text"
done < <(bash "$here/monitor.sh" --disks 2>/dev/null | awk -F'\t' -v max="$max_temp" '
  $6 == "FAIL"             { printf "disk:%s:smart\tdisk %s (%s) fails its SMART self-assessment\n", $1, $1, $4 }
  $9 != "-" && $9 + 0 > 0  { printf "disk:%s:pending\tdisk %s (%s) has %d pending sector(s)\n", $1, $1, $4, $9 }
  $5 != "-" && $5 + 0 >= max { printf "disk:%s:temp\tdisk %s (%s) is at %d °C\n", $1, $1, $4, $5 }' || true)

# disks the self-test log or the SMART values rate BAD (the checks above only see the overall verdict)
if [ "$(id -u)" -eq 0 ]; then
  while IFS=$'\t' read -r name _ _ model verdict _ why; do
    [ "$verdict" = BAD ] || continue
    problem "disk:$name:bad" "disk $name ($model) is rated BAD: $why. Details: hs disk $name health"
  done < <(bash "${HS_DISK_HEALTH:-$here/disk-health.sh}" --list 2>/dev/null || true)
fi
# disks the state database lists as missing (until they are forgotten) or getting worse, and a collector that stopped
# (scripts/state-db.py; nothing without a database or python)
while IFS=$'\t' read -r key text; do
  [ -n "$key" ] || continue
  problem "$key" "$text"
done < <(bash "$here/state.sh" problems 2>/dev/null || true)
# the live state of the web interface: Redis down, or a topic older than three intervals (texts are English)
if capability_on live-state; then
  while IFS=$'\t' read -r key text; do
    [ -n "$key" ] || continue
    problem "$key" "$text"
  done < <(bash "$here/live.sh" check 2>/dev/null || true)
fi
# the self-test schedule must keep running (state is written by hs disk selftest)
selftest_state=${HS_SELFTEST_STATE:-/var/lib/hs/selftest.state}
if [ -f "$selftest_state" ]; then
  s_short=$(sed -n 's/^short=//p' "$selftest_state"); s_long=$(sed -n 's/^long=//p' "$selftest_state")
  if [ -n "$s_short" ] && [ $(( now - s_short )) -gt $(( 14 * 86400 )) ]; then
    problem "selftest:short" "no short disk self-test for $(( (now - s_short) / 86400 )) days. Details: journalctl -u hs-selftest-short"
  fi
  if [ -n "$s_long" ] && [ $(( now - s_long )) -gt $(( 45 * 86400 )) ]; then
    problem "selftest:long" "no long disk self-test for $(( (now - s_long) / 86400 )) days. Details: journalctl -u hs-selftest-long"
  fi
fi

# ── Space ──
used_pct() { df --output=pcent "$1" 2>/dev/null | tail -n1 | tr -dc '0-9' || true; }
mounts=(/)
# on the ZFS layout /bulk is covered by the pool below
if [ "$bulk_type" = snapraid ] && mountpoint -q /bulk 2>/dev/null; then mounts+=(/bulk); fi
for m in "${mounts[@]}"; do
  pct=$(used_pct "$m")
  if [ -n "$pct" ] && [ "$pct" -ge "$max_full" ]; then
    problem "space:$m" "$m is $pct % full"
  fi
done
# The upload cache may fill up during a big upload (new files then go straight
# to the disks) and empties itself. Full while holding files older than an hour
# means the mover is not doing its job.
if mountpoint -q /mnt/bulk/cache 2>/dev/null; then
  pct=$(used_pct /mnt/bulk/cache)
  if [ -n "$pct" ] && [ "$pct" -ge "$max_full" ] &&
     [ -n "$(find /mnt/bulk/cache -type f -mmin +60 -print -quit 2>/dev/null)" ]; then
    problem "space:cache" "the upload cache is $pct % full and is not being emptied. Details: hs cache-mover"
  fi
fi
if have zpool; then
  while read -r p cap; do
    cap=${cap%\%}
    if [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -ge "$max_full" ]; then
      problem "space:pool:$p" "ZFS pool $p is $cap % full"
    fi
  done < <(zpool list -H -o name,cap 2>/dev/null || true)
fi

# ── A disk taken out of /bulk by hand (hs sys disk start detach) and forgotten: its files are missing for everyone meanwhile ──
for f in "${HS_STATE_DIR:-/var/lib/hs}"/detached/*; do
  [ -f "$f" ] || continue
  since=$(cat "$f" 2>/dev/null || echo 0)
  [[ "$since" =~ ^[0-9]+$ ]] || continue
  age=$(( now - since ))
  if [ "$age" -gt "${HS_DETACH_MAX:-7200}" ]; then
    problem "detached:${f##*/}" "${f##*/} has been detached for $(( age / 3600 )) hours: its files are missing in /bulk. Give it back: hs sys disk start attach ${f##*/}"
  fi
done

# A recovery that was started and never finished (hs sys disk start <member> recover-finish gives the disk back): its files are missing in /bulk
for f in "${HS_RECOVER_DIR:-${HS_STATE_DIR:-/var/lib/hs}/recovering}"/*; do
  [ -f "$f" ] || continue
  since=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
  age=$(( now - since ))
  if [ "$age" -gt "${HS_RECOVER_MAX:-259200}" ]; then
    problem "recovering:${f##*/}" "${f##*/} has been out of the pool for $(( age / 86400 )) days for a recovery: its files are missing in /bulk. When you are done: hs sys disk start ${f##*/} recover-finish"
  fi
done

# ── Failed services: the scheduled jobs (hs-*) and what the shares depend on ──
if have systemctl; then
  mapfile -t units < <(systemctl list-units --all --plain --no-legend 'hs-*.service' 2>/dev/null | awk '{ print $1 }' || true)
  for u in "${units[@]}" bulk-mount.service samba-smbd.service; do
    if systemctl is-failed --quiet "$u" 2>/dev/null; then
      problem "unit:$u" "$u failed. Details: journalctl -u $u"
    fi
  done
fi

# ── A disk mounted with hs disk temp and forgotten ──
temp_root=${HS_TEMP_ROOT:-/mnt/temp}
for d in "$temp_root"/*/; do
  [ -d "$d" ] && mountpoint -q "$d" || continue
  t_name=$(basename "$d")
  t_since=$(cat "${HS_RUN_DIR:-/run/hs}/temp-$t_name.since" 2>/dev/null || true)
  [[ "$t_since" =~ ^[0-9]+$ ]] || continue          # mounted by hand, not by hs disk temp
  t_age=$(( (now - t_since) / 86400 ))
  if [ "$t_age" -ge 2 ]; then
    problem "temp:$t_name" "temp disk $t_name has been mounted for $t_age days (and is shared as temp-$t_name). Done with it? hs disk temp eject $t_name"
  fi
done

# ── Encrypted storage waiting for the passphrase ──
if [ -e "${HS_RUN_DIR:-/run/hs}/storage-locked" ]; then
  problem "storage:locked" "encrypted disks are locked: the pools, containers and shares wait for the passphrase. Run: hs unlock"
fi

# ── Backup (only once hs backup init has run): recent, not failed, disk not full ──
backup_state=${HS_BACKUP_STATE:-/var/lib/hs/backup.state}
if [ -f "$backup_state" ]; then
  b_ok=$(sed -n 's/^last_ok=//p' "$backup_state")
  b_status=$(sed -n 's/^status=//p' "$backup_state")
  b_used=$(sed -n 's/^used_pct=//p' "$backup_state")
  if [ -z "$b_ok" ]; then
    [ "$b_status" = new ] || problem "backup:never" "no backup has finished yet. Run: hs backup now"
  elif [ $((now - b_ok)) -gt 129600 ]; then
    problem "backup:stale" "last successful backup is $(( (now - b_ok) / 3600 )) hours old. Details: journalctl -u hs-backup, or hs backup status"
  fi
  [ "$b_status" = failed ] && problem "backup:failed" "the last backup run had errors. Details: journalctl -u hs-backup"
  # a backup nobody has restored from is a hope: the monthly drill must keep succeeding
  b_drill=$(sed -n 's/^drill_ok=//p' "$backup_state"); b_first=$(sed -n 's/^first_ok=//p' "$backup_state")
  if [ -n "$b_drill" ]; then
    [ $(( now - b_drill )) -le $(( 45 * 86400 )) ] || problem "backup:drill" "the last successful restore drill is $(( (now - b_drill) / 86400 )) days old. Try: hs backup drill"
  elif [ -n "$b_first" ] && [ $(( now - b_first )) -gt $(( 45 * 86400 )) ]; then
    problem "backup:drill" "no restore drill has succeeded yet. Try: hs backup drill"
  fi
  # the same for a container: only once one drill has worked (the drill is monthly, 90 days is three misses)
  b_ctdrill=$(sed -n 's/^drill_ct_ok=//p' "$backup_state")
  if [ -n "$b_ctdrill" ] && [ $(( now - b_ctdrill )) -gt $(( 90 * 86400 )) ]; then
    problem "backup:drill-ct" "the last successful container restore drill is $(( (now - b_ctdrill) / 86400 )) days old. Try: hs backup drill ct"
  fi
  b_off=$(sed -n 's/^offsite=//p' "$backup_state")
  b_offok=$(sed -n 's/^offsite_ok=//p' "$backup_state")
  if [ "${b_off:-0}" = 1 ] && { [ -z "$b_offok" ] || [ $((now - b_offok)) -gt 259200 ]; }; then
    problem "backup:offsite" "the off-site copy of the backup is more than 3 days old (or never ran). Try: hs backup offsite now"
  fi
  if [ "${b_used:-0}" -ge 85 ]; then
    problem "backup:full" "the backup disk is ${b_used}% full: leave shares out (\`hs backup <share> off\`) or use a bigger disk"
  fi
fi

# ── UPS (only when machine.toml sets `ups`; /etc/hs/ups exists then; scripts/ups.sh) ──
if [ -f "${HS_UPS_CONF:-/etc/hs/ups}" ]; then
  ups_out=$(bash "$here/ups.sh" status 2>/dev/null || true)
  ups_get() { printf '%s\n' "$ups_out" | sed -n "s/^$1\t//p" | head -n1; }
  if [ "$(ups_get reachable)" != yes ]; then
    problem "ups:unreachable" "the UPS cannot be read. Look: hs ups"
  else
    case "$(ups_get state)" in
      battery) problem "ups:onbattery" "the power is out, the server runs on the UPS battery (charge $(ups_get charge)%). Look: hs ups" ;;
      low) problem "ups:lowbattery" "the power is out and the UPS battery is low. Look: hs ups" ;;
    esac
    [ "$(ups_get replace)" != yes ] || problem "ups:replace" "the UPS says its battery should be replaced. Look: hs ups"
  fi
fi

# ── Certificate of the domain controller (only where its instance runs: dc1, dc2, dcName; lib/dc.sh) ──
dcn=$(dc_name)
if have incus && incus list -c ns -f csv 2>/dev/null | grep -qx "$dcn,RUNNING"; then
  # timeout: never let a hanging container block the whole check
  end=$(timeout 30 incus exec "$dcn" -- openssl x509 -enddate -noout \
    -in /var/lib/samba/private/tls/cert.pem 2>/dev/null </dev/null | sed -n 's/^notAfter=//p' || true)
  if [ -n "$end" ] && ends=$(date -d "$end" +%s 2>/dev/null); then
    days=$(( (ends - now) / 86400 ))
    if [ "$ends" -le "$now" ]; then
      problem "cert:$dcn" "the domain controller's certificate ($dcn) has expired"
    elif [ "$days" -lt "$cert_days" ]; then
      problem "cert:$dcn" "the domain controller's certificate ($dcn) expires in $days day(s)"
    fi
  fi
fi

# ── Shares everybody may open (only in a domain, where access is per user) ──
# New shares start closed there; one that lists "Everyone" was created before
# the domain join or opened by hand. Needs root, skipped otherwise.
if [ "$(id -u)" -eq 0 ] && [ "$(testparm -s --parameter-name=security 2>/dev/null)" = "ADS" ]; then
  for s in $(net conf listshares 2>/dev/null || true); do
    if sharesec "$s" --view 2>/dev/null | grep -q '^ACL:S-1-1-0:ALLOWED'; then
      problem "share:$s:open" "share $s is open to everyone. Set who may use it: hs share $s perm"
    fi
  done
fi

# ── Configuration drift: the checkout in /etc/nixos against Git and against what is running ──
# Cheap on purpose (local git only, no fetch, no build): uncommitted changes and local commits are not in Git (a rebuild of a
# fresh clone would differ); a diverged branch makes `hs update` (git pull --ff-only) stop; rebuild.sh writes the revision it
# switched to into last-rebuild-rev, so a different HEAD means the running system is not what the checkout would build.
cfg_repo=${HS_REPO:-/etc/nixos}
cfg_state=${HS_STATE_DIR:-/var/lib/hs}
if have git && [ -e "$cfg_repo/.git" ]; then
  cg() { git -c safe.directory="$cfg_repo" -C "$cfg_repo" "$@"; }
  if [ -n "$(cg status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
    problem "config:dirty" "$cfg_repo has uncommitted changes, so Git does not match what runs and \`hs update\` may stop. Look at: git -C $cfg_repo status"
  fi
  if ab=$(cg rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null); then
    read -r c_ahead c_behind <<<"$ab"
    if [ "${c_ahead:-0}" -gt 0 ] && [ "${c_behind:-0}" -gt 0 ]; then
      problem "config:diverged" "$cfg_repo has $c_ahead local and $c_behind new upstream commit(s): \`hs update\` will stop (it only fast-forwards). Look at: git -C $cfg_repo log --oneline @{u}.."
    elif [ "${c_ahead:-0}" -gt 0 ]; then
      problem "config:ahead" "$cfg_repo has $c_ahead commit(s) that are not pushed. Push them: git -C $cfg_repo push"
    fi
  fi
  if [ -r "$cfg_state/last-rebuild-rev" ]; then
    c_ran=$(sed -n 's/^rev=//p' "$cfg_state/last-rebuild-rev" | head -n1)
    c_head=$(cg rev-parse HEAD 2>/dev/null || true)
    if [ -n "$c_ran" ] && [ -n "$c_head" ] && [ "$c_ran" != "$c_head" ]; then
      problem "config:unbuilt" "the running system was built from ${c_ran:0:8}, the checkout is at ${c_head:0:8}. Apply it: hs rebuild"
    fi
  fi
fi

# ── Things that run out on a date (hs expiry list) ──
# 30 days before: "soon"; 7 days before and after the date: "due" / "expired" (the key changes with the stage, so each stage is sent).
if [ -r "${HS_STATE_DIR:-/var/lib/hs}/expiry" ]; then
  while IFS=$'\t' read -r e_name e_date e_days e_state e_how; do
    [ -n "$e_name" ] || continue
    e_fix=""; [ -z "$e_how" ] || e_fix=" Renew: $e_how"
    case "$e_state" in
      soon)    problem "expiry:$e_name:soon" "$e_name runs out on $e_date (in $e_days days).$e_fix" ;;
      due)     problem "expiry:$e_name:due" "$e_name runs out on $e_date (in $e_days day(s)): renew it now.$e_fix" ;;
      expired) problem "expiry:$e_name:expired" "$e_name ran out on $e_date ($(( -e_days )) day(s) ago).$e_fix" ;;
      invalid) problem "expiry:$e_name:invalid" "the date of the entry $e_name ('$e_date') is not YYYY-MM-DD. Fix: hs expiry add $e_name <YYYY-MM-DD>" ;;
    esac
  done < <(bash "$here/expiry.sh" --list 2>/dev/null || true)
fi

# ── Capacity and trends: pools filling up, SSD wear, a cache that is not drained, a backup disk getting full ──
# The readings go to the state database (scripts/state.sh) at most once an hour per volume; nothing is written in a dry run.
$dry || capacity_record
while IFS=$'\t' read -r key text; do
  [ -n "$key" ] || continue
  problem "$key" "$text"
done < <(capacity_problems)

# ── Notifications (capability notifications): while the storage is locked every service on this server is down, so one enabled channel
# outside it must carry the alarms. The key has no digits. A caller that cannot read the (root only) channel folder skips the check.
if capability_on notifications && ! { [ -d "$(chan_dir)" ] && [ ! -r "$(chan_dir)" ]; }; then
  if ! chan_has_outside_alarm; then
    problem "notify:no-outside-channel" "no enabled notification channel outside this server carries alarms. While the storage is locked this server is down and you will not hear about it. Add one: Notifications in the web interface, or hs notify channel add <name> --provider ntfy --secret url"
  fi
fi

# ── Acknowledged problems (hs health ack <id>): not sent and not counted until they clear ──
declare -A acked=()
if [ -r "$ack_file" ]; then
  while IFS=$'\t' read -r ak _; do
    [ -z "$ak" ] || acked["$ak"]=1
  done < "$ack_file"
fi

# ── Automatic mitigation, level 1: notify and pause. Off unless the setting autoMitigate is true. ──
# A failing disk (SMART red or rated BAD) or a degraded pool / missing bulk disk pauses the parity sync, the scrub and the
# cache mover (the pause marker lib/bulklock.sh checks). Nothing is deleted, formatted or moved. The pause lifts itself when
# the cause is gone; `hs health resume` lifts it by hand and acknowledges its causes.
mit_on=${HS_AUTO_MITIGATE-$(setting_get autoMitigate 2>/dev/null || true)}
triggers=()
for k in "${keys[@]}"; do
  [ -z "${acked[$k]:-}" ] || continue
  case "$k" in
    disk:*:smart|disk:*:bad) triggers+=("$k") ;;
    zfs:*:scrub-*) ;;
    zfs:*:*) triggers+=("$k") ;;
    bulk:*:*) triggers+=("$k") ;;
  esac
done
if ! $dry; then
  if [ "$mit_on" = true ] && [ ${#triggers[@]} -gt 0 ]; then
    want=$(printf 'auto=1\nkeys=%s\n' "$(IFS=,; echo "${triggers[*]}")")
    if [ "$(sed '/^since=/d' "$bulk_pause" 2>/dev/null || true)" != "$want" ]; then
      printf '%s\nsince=%s\n' "$want" "$now" > "$bulk_pause" 2>/dev/null || true
    fi
  elif [ -f "$bulk_pause" ] && grep -q '^auto=1' "$bulk_pause" 2>/dev/null; then
    rm -f "$bulk_pause"      # cause gone, or the switch was turned off
  fi
fi
if [ -f "$bulk_pause" ]; then
  problem "mitigation:paused" "the parity sync, the scrub and the cache mover are paused because of $(sed -n 's/^keys=//p' "$bulk_pause" | head -n1 | sed 's/,/, /g'). Nothing was deleted or changed. Fix the cause, or lift the pause: hs health resume"
fi

if $keys_only; then
  [ ${#keys[@]} -eq 0 ] || printf '%s
' "${keys[@]}"
  exit 0
fi

# Since when each problem is open: key TAB time, the first time the key was seen in the current set (a key that cleared is dropped, so a
# return starts again). Plain file next to the acknowledgements, written by every run that can write it (also --list), never by --keys.
# The channels that took the last message about a key are kept by notify.sh (chan_told_get).
since_file=${HS_SINCE_FILE:-$(dirname "$ack_file")/health-since}
declare -A since=()
if [ -r "$since_file" ]; then
  while IFS=$'\t' read -r sk st; do [[ "$st" =~ ^[0-9]+$ ]] && since[$sk]=$st; done < "$since_file"
fi
if ! $test_msg && { mkdir -p "$(dirname "$since_file")" 2>/dev/null; [ -w "$(dirname "$since_file")" ] && { [ ! -e "$since_file" ] || [ -w "$since_file" ]; }; }; then
  {
    for k in "${keys[@]}"; do printf '%s\t%s\n' "$k" "${since[$k]:-$now}"; done
  } > "$since_file.new" 2>/dev/null && mv "$since_file.new" "$since_file" || rm -f "$since_file.new"
  chan_told_prune < <(printf '%s\n' "${keys[@]:-}") 2>/dev/null || true
fi

if $list_only; then
  # key, text, acked|-, since (epoch seconds), channels that took the last message (comma separated or -)
  for i in "${!keys[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\n' "${keys[$i]}" "${texts[$i]}" "$([ -n "${acked[${keys[$i]}]:-}" ] && echo acked || echo -)" \
      "${since[${keys[$i]}]:-$now}" "$(chan_told_get "${keys[$i]}" 2>/dev/null || echo -)"
  done
  exit 0
fi

# the acknowledged ones leave the lists; an entry whose problem is gone is dropped from the file
n_acked=0
if [ ${#acked[@]} -gt 0 ]; then
  nk=(); nt=(); present=""
  for i in "${!keys[@]}"; do
    if [ -n "${acked[${keys[$i]}]:-}" ]; then n_acked=$((n_acked + 1)); present+="${keys[$i]}"$'\n'; continue; fi
    nk+=("${keys[$i]}"); nt+=("${texts[$i]}")
  done
  keys=("${nk[@]}"); texts=("${nt[@]}")
  if ! $dry && [ -w "$ack_file" ]; then
    awk -F'\t' 'NR == FNR { p[$0] = 1; next } ($1 in p)' <(printf '%s' "$present") "$ack_file" > "$ack_file.tmp" 2>/dev/null &&
      mv "$ack_file.tmp" "$ack_file" || rm -f "$ack_file.tmp"
  fi
fi

# ── Result, also when nothing is sent ──
if [ ${#texts[@]} -eq 0 ]; then
  echo "No problems found."
else
  printf '%s\n' "${texts[@]}"
fi

# ── Numbers for Prometheus (machine.toml: metrics = true; hs recipe monitoring) ──
# node-exporter reads every *.prom file in this folder.
prom=/var/lib/hs/metrics
if [ -d "$prom" ] && [ -w "$prom" ]; then
  {
    echo "# HELP hs_problems Problems found by hs health at its last run"
    echo "# TYPE hs_problems gauge"
    echo "hs_problems ${#texts[@]}"
    echo "# TYPE hs_health_check_timestamp_seconds gauge"
    echo "hs_health_check_timestamp_seconds $now"
    if [ -e /var/lib/snapraid/snapraid.content ]; then
      echo "# HELP hs_snapraid_last_sync_timestamp_seconds When the parity was last updated"
      echo "# TYPE hs_snapraid_last_sync_timestamp_seconds gauge"
      echo "hs_snapraid_last_sync_timestamp_seconds $(stat -c %Y /var/lib/snapraid/snapraid.content)"
    fi
    if mountpoint -q /mnt/bulk/cache 2>/dev/null; then
      echo "# HELP hs_cache_waiting_bytes Uploads in the SSD cache that are not on the data disks yet"
      echo "# TYPE hs_cache_waiting_bytes gauge"
      echo "hs_cache_waiting_bytes $(df -B1 --output=used /mnt/bulk/cache | tail -n1 | tr -dc '0-9')"
    fi
  } > "$prom/hs.prom.tmp" && mv "$prom/hs.prom.tmp" "$prom/hs.prom"
fi

# ── "Still alive" for the watcher outside (heartbeatUrl in machine.toml; scripts/vps-watch.sh) ──
# Sent at every real run, also with problems; it never fails the check.
# The heartbeat is a message class: notify.sh hands it to the channels that carry `heartbeat` (the old
# heartbeatUrl is derived as one), bypassing the quiet hours, the minimum priority and the digest. No such channel, nothing is sent.
if ! $dry && ! $test_msg && have curl; then
  NTFY_TIMEOUT=15 bash "$here/notify.sh" --category heartbeat "$host alive" "alive, ${#texts[@]} problem(s)" 2>/dev/null || true
fi

send() {   # title, message, priority, category
  if $dry; then bash "$here/notify.sh" --dry-run --category "$4" "${@:1:3}"
  else
    # the problems a "problem" message is about: notify.sh records which channels took it (shown by hs sys health list)
    local nk=""
    [ "$4" != problem ] || nk=$(IFS=,; echo "${keys[*]:-}")
    HS_NOTIFY_KEYS=$nk bash "$here/notify.sh" --category "$4" "${@:1:3}"
  fi
}

# Messages the quiet hours held back go out once the window is over (a no-op inside it or when nothing is held).
if ! $dry && ! $test_msg; then bash "$here/notify.sh" --flush 2>/dev/null || true; fi

if $test_msg; then
  echo
  send "$host: test" "Test message from \`hs health\`: notifications work." default ok
  exit 0
fi

# ── Send only when something changed ──
# State file: first line = time of the last message, then the keys it listed.
new=""
[ ${#keys[@]} -eq 0 ] || new=$(printf '%s\n' "${keys[@]}" | sort)
last=0
old=""
if [ -r "$state" ]; then
  last=$(head -n1 "$state")
  old=$(tail -n +2 "$state")
fi
[[ "$last" =~ ^[0-9]+$ ]] || last=0

if ! $dry && ! { mkdir -p "$(dirname "$state")" 2>/dev/null && [ -w "$(dirname "$state")" ]; }; then
  echo
  echo "Can't write $state (not root?): nothing is sent, showing only."
  dry=true
fi

# A forecast below 7 days to full (key forecast:<volume>:urgent) sends urgent instead of high; quiet hours never hold it.
prio=high
for k in "${keys[@]}"; do case "$k" in forecast:*:urgent) prio=urgent ;; esac; done

echo
[ "$n_acked" -eq 0 ] || echo "$n_acked acknowledged problem(s) are not counted. See: hs health ack"
count="${#texts[@]} problem(s)"
if [ "$new" != "$old" ] && [ -n "$new" ]; then
  send "$host: $count" "$(echo '**Needs attention**'; printf '%s\n' "${texts[@]}")" "$prio" problem
elif [ "$new" != "$old" ]; then
  send "$host: all clear" "**All clear.** The problems reported earlier are gone." default ok
elif [ -n "$new" ] && [ $((now - last)) -ge "$remind" ]; then
  send "$host: still $count" "$(echo '**Still open since the last message**'; printf '%s\n' "${texts[@]}")" "$prio" problem
else
  echo "Nothing to send: unchanged since the last message."
  exit 0
fi

$dry || printf '%s\n%s\n' "$now" "$new" > "$state"
