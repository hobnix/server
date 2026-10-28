#!/usr/bin/env bash
# help: quick check that the commands work on this server: tools they need are installed, read-only commands run without errors
# help.de: schneller Test, ob die Befehle auf diesem Server funktionieren: die nötigen Programme sind da, lesende Befehle laufen ohne Fehler
# args: [--list] [--no-run] [--coverage]
# --coverage = developer check, runs nothing: every user row of the registry flagged `reads` must have a probe (default_probes below)
# or an entry in SKIP_READS with the reason, and a skip entry must still name a `reads` row; prints what is missing, exit 1.
# tests/smoke.sh runs it, so a new read-only command cannot be added without a probe. Probe line: label, words, ok exit codes, time limit.
# Changes nothing: step 1 looks for the programs the scripts call (incus, zpool, smartctl, restic, ...); step 2 runs a fixed
# list of read-only commands (hs ct list, hs disk list, hs user list, ...) with a time limit and calls it a failure when
# one exits with an error or prints "command not found" / "syntax error". Needs root (like most commands).
# --list = kind<TAB>name<TAB>ok|fail|skip<TAB>detail. Exit 1 when something failed.
# HS_SMOKE_HS (a replacement for lib/hs.sh), HS_SMOKE_PROBES (a file: label<TAB>words<TAB>ok exit codes), HS_SMOKE_TIMEOUT,
# HS_SMOKE_TOOLS (space separated), HS_BULK: tests.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
hs_sh=${HS_SMOKE_HS:-$here/lib/hs.sh}
limit=${HS_SMOKE_TIMEOUT:-60}
bulk=${HS_BULK:-/bulk}

list=false; run=true; coverage=false
for a in "$@"; do
  case "$a" in
    --list) list=true ;;
    --no-run) run=false ;;
    --coverage) coverage=true ;;
    *) say "usage: hs smoke [--list] [--no-run] [--coverage]"; exit 1 ;;
  esac
done

fails=0; oks=0; skips=0
result() {   # result <kind> <name> <ok|fail|skip> <detail>
  case "$3" in ok) oks=$((oks + 1)) ;; fail) fails=$((fails + 1)) ;; skip) skips=$((skips + 1)) ;; esac
  if $list; then printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; return; fi
  case "$3" in
    ok) ok "$2${4:+  ($4)}" ;;
    fail) warn "$2: $4" ;;
    skip) note "$2: $4" ;;
  esac
}

# does the registry have a row for these words? (<values> in a path match any word)
registry=${HS_REGISTRY:-$here/lib/registry.tsv}
. "$here/lib/registry-load.sh"   # the core list plus the commands of the extensions that are on
in_registry() {
  awk -F'\t' -v w="$1" '$1 == "user" || ($1 == "sys" && substr(w, 1, 4) == "sys ") {
    n = split($2, p, " "); m = split(w, q, " ")
    if (n > m) next
    for (i = 1; i <= n; i++) if (substr(p[i], 1, 1) != "<" && p[i] != q[i]) next
    found = 1
  } END { exit !found }' <(registry_rows)
}

# ---- the probes and the rows that are left out on purpose ----------------------------------------
# One line per read-only user command (registry flag `reads`): label, words, ok exit codes, time limit (optional), tab separated.
# The words resolve to the longest registry row they match. Exit 1 is allowed where a command reports findings with it (doctor,
# ports ...) or works on something that may not exist yet (no backup disk, no UniFi key). A value that cannot be found here
# (no container, no disk) drops the probes that need it. In --coverage mode the values are placeholders.
default_probes() {
  local first_share first_ct first_disk
  if $coverage; then first_share=X; first_ct=X; first_disk=X
  else
    first_share=$(ls "$bulk/shares" 2>/dev/null | head -n 1 || true)
    first_ct=$("${HS_INCUS:-incus}" list -c n -f csv 2>/dev/null </dev/null | head -n 1 || true)
    first_disk=$(lsblk -dno NAME 2>/dev/null | grep -E '^(sd|nvme|vd)' | head -n 1 || true)
  fi
  printf '%s\n' \
    $'help\thelp\t0' \
    $'hs status\tstatus\t0 1' \
    $'hs health\thealth\t0 1\t120' \
    $'hs ct list\tct list\t0' \
    $'hs disk list\tdisk list\t0 1' \
    $'hs disk events\tdisk events\t0 1' \
    $'hs disk inventory\tdisk inventory\t0 1' \
    $'hs pool bulk\tpool bulk\t0 1' \
    $'hs sys pool state\tsys pool state\t0' \
    $'hs user list\tuser list\t0' \
    $'hs user show\tuser Administrator show\t0 1' \
    $'hs group list\tgroup list\t0' \
    $'hs group show\tgroup Administrators show\t0 1' \
    $'hs job list\tjob list\t0' \
    $'hs job running\tjob running\t0' \
    $'hs job log\tjob log hs-health-check.service\t0 1' \
    $'hs config list\tconfig list\t0' \
    $'hs preset list\tpreset list\t0' \
    $'hs preset show minimal\tpreset show minimal\t0' \
    $'hs config get\tconfig get language\t0 1' \
    $'hs config check\tconfig check\t0 1' \
    $'hs backup\tbackup\t0 1' \
    $'hs backup status\tbackup status\t0' \
    $'hs backup list\tbackup list\t0 1' \
    $'hs backup find\tbackup find machine.toml\t0 1' \
    $'hs system info\tsystem info\t0' \
    $'hs secrets\tsecrets\t0' \
    $'hs cleanup\tcleanup\t0' \
    $'hs doctor\tdoctor\t0 1' \
    $'hs snapshots list\tsnapshots list\t0' \
    $'hs motd\tmotd --force\t0' \
    $'hs monitor\tmonitor --plain\t0 1' \
    $'hs ports\tports\t0 1\t120' \
    $'hs timing\ttiming\t0 1\t120' \
    $'hs vault status\tvault status\t0 1' \
    $'hs vault list\tvault list\t0 1' \
    $'hs net check\tnet check\t0 1' \
    $'hs dns list\tdns list\t0 1' \
    $'hs services list\tservices list\t0 1' \
    $'hs services check\tservices check\t0 1' \
    $'hs services plan\tservices plan\t0 1' \
    $'hs services tiles\tservices tiles\t0 1' \
    $'hs gateway status\tgateway status\t0 1' \
    $'hs gateway routes\tgateway routes\t0 1' \
    $'hs gateway check\tgateway check\t0 1' \
    $'hs dc cert show\tdc cert show\t0 1' \
    $'hs update --preview\tupdate --preview\t0 1\t120' \
    $'hs ssh-key list\tssh-key list\t0 1' \
    $'hs node list\tnode list\t0' \
    $'hs notify channel list\tnotify channel list\t0' \
    $'hs notify channel providers\tnotify channel providers\t0' \
    $'hs ext games list\text games list\t0 1' \
    $'hs remote list\tremote list\t0 1' \
    $'hs cheatsheet\tcheatsheet\t0' \
    $'hs expiry\texpiry\t0' \
    $'hs ups\tups\t0 1' \
    $'hs pkg list\tpkg list\t0' \
    $'hs pkg updates\tpkg updates\t0 1'
  if [ -n "$first_share" ]; then
    printf '%s\t%s\t%s\n' "hs share $first_share show" "share $first_share show" "0" "hs share $first_share snapshots" "share $first_share snapshots" "0 1"
  fi
  if [ -n "$first_ct" ]; then
    printf '%s\t%s\t%s\n' "hs ct $first_ct snapshots" "ct $first_ct snapshots" "0 1" "hs ct $first_ct storage list" "ct $first_ct storage list" "0 1" "hs ct $first_ct logs" "ct $first_ct logs 5" "0 1"
  fi
  if [ -n "$first_disk" ]; then
    printf '%s\t%s\t%s\t%s\n' "hs disk $first_disk health" "disk $first_disk health" "0 1" 120 "hs disk $first_disk results" "disk $first_disk results" "0 1" ""
  fi
}
# reads rows that have no probe, with the reason (one per line: registry path, TAB, reason)
SKIP_READS=$'smoke	it is this command (it would call itself)
node show	needs a registered node (probed by tests/node.sh)
node status	needs a registered node that answers over ssh
notify channel show	needs a channel name (probed by tests/notify-channel.sh)
pc list	the old word of hs ext games list, which is probed
ext list	the same script as hs ext games list, which is probed (the row `ext <name>` of the same length hides this one from the matcher)
pkg validate	checks one folder given as argument (tests/pkg.sh)
pkg repo list	probed as pkg repo list is empty without repositories (tests/pkg-repo.sh)
pkg available	needs a fetched repository (tests/pkg-repo.sh)'

if $coverage; then
  cov=$(mktemp -d); trap 'rm -rf "$cov"' EXIT
  registry_rows > "$cov/rows"
  printf '%s\n' "$SKIP_READS" | cut -f1 > "$cov/skip"
  default_probes | cut -f2 > "$cov/probes"
  awk -F'\t' '
    FILENAME == ARGV[1] { skip[$1] = 1; next }
    FILENAME == ARGV[2] {
      if ($1 != "user") next
      rows[$2] = 1
      if (("," $7 ",") ~ /,reads,/) reads[$2] = 1
      next
    }
    {
      m = split($0, q, " "); best = ""; bn = 0
      for (r in rows) {
        n = split(r, p, " "); if (n > m || n <= bn) continue
        good = 1
        for (i = 1; i <= n; i++) if (substr(p[i], 1, 1) != "<" && p[i] != q[i]) { good = 0; break }
        if (good) { best = r; bn = n }
      }
      if (best != "") covered[best] = 1
    }
    END {
      bad = 0
      for (r in reads) if (!(r in covered) && !(r in skip)) { print "no probe and no skip entry: " r; bad = 1 }
      for (r in skip) if (!(r in reads)) { print "stale skip entry (not a reads row): " r; bad = 1 }
      exit bad
    }' "$cov/skip" "$cov/rows" "$cov/probes"
  rc=$?
  [ "$rc" -ne 0 ] || echo "every reads row has a probe or a reason"
  exit "$rc"
fi

# ---- 1. the programs the scripts call ------------------------------------------------------
tools=${HS_SMOKE_TOOLS-"incus zpool zfs smartctl restic samba-tool wbinfo sharesec snapraid mergerfs cryptsetup lsblk blkid jq curl rsync sgdisk wipefs systemctl git setfacl getfacl xfs_admin e2label btrfs mkfs.ext4 findmnt nix-env"}
$list || step "Programs the scripts need"
for tool in $tools; do
  if command -v "$tool" >/dev/null 2>&1; then continue; fi
  users=$(grep -lwE -- "$tool" "$here"/*.sh "$here"/recipes/*.sh "$here"/../packages/*/run.sh 2>/dev/null | while read -r f; do
    [ "$(basename "$f")" != smoke.sh ] || continue
    grep -v '^[[:space:]]*#' "$f" | grep -qwE -- "$tool" && basename "$f" .sh
  done | sort -u | head -n 6 | paste -sd' ' -)
  [ -n "$users" ] || continue
  result tool "$tool" fail "$(t 'not installed; used by: %s' "$users")"
done
if ! command -v gum >/dev/null 2>&1; then
  result tool gum skip "$(t 'not installed: the commands print plain text instead of the styled version')"
fi
[ "$fails" -gt 0 ] || result tool "all other programs" ok ""

# ---- 2. read-only commands -------------------------------------------------------------------
if $run; then
  $list || step "Read-only commands"
  probes=$(default_probes)
  [ -z "${HS_SMOKE_PROBES:-}" ] || probes=$(cat "$HS_SMOKE_PROBES")
  while IFS=$'\t' read -r label words codes plimit; do
    [ -n "$label" ] || continue
    # a command this version does not have (the list below is longer than an old checkout) is skipped
    if [ "$words" != help ] && ! in_registry "$words"; then result probe "$label" skip "$(t 'no such command in this version')"; continue; fi
    out=$(HS_CALLER=smoke HS_PLAIN=1 timeout "${plimit:-$limit}" bash "$hs_sh" $words </dev/null 2>&1); rc=$?
    bad=$(grep -m1 -iE 'command not found|syntax error|unbound variable|No such file or directory|Traceback' <<<"$out" || true)
    if [ "$rc" = 124 ]; then
      result probe "$label" fail "$(t 'no answer after %s seconds' "${plimit:-$limit}")"
    elif [ -n "$bad" ]; then
      result probe "$label" fail "$(printf '%s' "$bad" | cut -c1-120)"
    elif ! grep -qw -- "$rc" <<<"${codes:-0}"; then
      result probe "$label" fail "$(t 'exit code %s' "$rc"): $(printf '%s' "$out" | tail -n 1 | cut -c1-100)"
    else
      result probe "$label" ok ""
    fi
  done <<<"$probes"
fi

if ! $list; then
  step "Result"
  if [ "$fails" -eq 0 ]; then status_line "Checks" "$(t '%s passed, %s skipped' "$oks" "$skips")" ok; else status_line "Checks" "$(t '%s of %s failed' "$fails" "$((oks + fails))")" bad; fi
fi
[ "$fails" -eq 0 ]
