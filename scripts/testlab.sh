#!/usr/bin/env bash
# help: the test-lab: fetch a Hobnix ref, build the installer ISO, install it in a nested VM and smoke check it (stages 1 and 2); plan first, runs as a job
# help.de: das Testlabor: einen Hobnix-Stand holen, die Installer-ISO bauen, in einer verschachtelten VM installieren und prüfen (Stufen 1 und 2); erst der Plan, läuft als Job
# args: run [--ref <branch|tag|commit>] [--stage 1|2|all|upgrade] [--from <vX.Y.Z>] [--dry-run] [--yes] [--background|--foreground] | results [--list [N]]
# UNVERIFIED: written without Incus, KVM or nix. Not tested on hardware yet. Design: capabilities/testlab/NOTES.md, docs/adr/0023-nested-test-harness.md.
#
#   run      builds the ISO of the ref and runs scripts/dev/nested.sh of THAT checkout. Stage 1: the ISO boots and installs unattended. Stage 2: the
#            installed system boots and passes the smoke check (needs stage 1, so --stage 2 and all run both). --dry-run prints the plan and
#            changes nothing. On a terminal it asks once, then whether to run as a background job; a job, --yes and the timer ask nothing.
#   upgrade  (#435, not part of `all`) the update path: builds the ISO of the last release (--from vX.Y.Z, default the newest tag), installs it,
#            sets up a share (and an app, HS_NESTED_UPGRADE_APP), runs `hs update` to --ref (a BRANCH of the Hobnix repository, default develop)
#            and checks health, shares, state.db and the app. Writes stage-upgrade.json. Takes two ISO builds' worth of time. Not tested on hardware yet.
#   results  the last runs, one line per run and stage; --list: machine-readable (run, stage, result, exit, ref, commit, started, ended; `-` = empty)
#
# The ref is fetched by this script and only from the Hobnix repositories (testlab_url_ok): a branch, a tag or a commit. A pull request ref, a
# fork or any other address is refused, so code of a stranger never runs here. It is not a GitHub runner: nothing starts from outside.
# Every run: /var/lib/hs/testlab/runs/<run-id>/ with stage-1.json, stage-2.json (result ok|failed|skipped|error) and run.log; the last HS_TESTLAB_KEEP
# (14) are kept. The VM is deleted at the end (also after a failure or a cancel). A failure or error sends a push message and the event testlab.failed.
# Exit codes: 0 passed, 1 a stage failed, 2 usage or refused, 3 cannot run here (skipped, no push message), 4 infrastructure error (fetch, build, Incus).
# Test knobs: HS_TESTLAB_DIR, HS_TESTLAB_REPO (still checked against the allowlist), HS_TESTLAB_GIT, HS_TESTLAB_BUILD_TIMEOUT, HS_TESTLAB_RUN_TIMEOUT,
# HS_TESTLAB_KEEP, HS_NESTED_INCUS, HS_NOTIFY (stand-in for notify.sh), HS_GUIDED_TTY=1 (there is a terminal; answers on stdin).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib/ui.sh"
. "$here/lib/capability.sh"
. "$here/lib/event.sh"
. "$here/lib/job.sh"

state=${HS_TESTLAB_DIR:-${HS_STATE_DIR:-/var/lib/hs}/testlab}
git=${HS_TESTLAB_GIT:-git}
incus=${HS_NESTED_INCUS:-incus}
repo_url=${HS_TESTLAB_REPO:-https://github.com/hobnix/server.git}

usage() {
  say "usage: hs testlab run [--ref <branch|tag|commit>] [--stage 1|2|all|upgrade] [--from <vX.Y.Z>] [--dry-run] [--yes] [--background|--foreground]"
  say "       hs testlab results [--list [N]]"
  exit 2
}
interactive() { [ -t 0 ] && [ -t 1 ] && [ -z "${HS_CALLER:-}" ] || [ -n "${HS_GUIDED_TTY:-}" ]; }

# The allowlist: only https addresses of repositories of the organisation hobnix on GitHub (no credentials, no other host, no path tricks).
testlab_url_ok() {
  case "$1" in https://github.com/hobnix/*) ;; *) return 1 ;; esac
  [[ "${1#https://github.com/hobnix/}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]
}
# A ref is a branch, a tag or a commit name. Never a pull request, a refspec or something git could read as an option.
testlab_ref_ok() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] || return 1
  case "$1" in refs/*|pull/*|*..*|*//*|*/|*.lock) return 1 ;; esac
  return 0
}

cmd=${1:-}
[ $# -eq 0 ] || shift
case "$cmd" in run|results) ;; *) usage ;; esac

capability_on testlab || fail "The test-lab is off. Switch it on with the capability testlab (hs config set capabilities, then hs rebuild)."

# ---------------------------------------------------------------- results
if [ "$cmd" = results ]; then
  list=false; n=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --list) list=true; shift; if [[ "${1:-}" =~ ^[0-9]{1,3}$ ]]; then n=$1; shift; fi ;;
      *) usage ;;
    esac
  done
  rows=$(python3 -I - "$state/runs" "$n" <<'PY'
import json, os, sys
runs, n = sys.argv[1], int(sys.argv[2])
try:
    names = sorted(d for d in os.listdir(runs) if os.path.isdir(os.path.join(runs, d)))[-n:]
except OSError:
    names = []
def clean(v):
    s = str(v if v not in (None, "") else "-")
    return s.replace("\t", " ").replace("\n", " ")
for name in names:
    for stage in (1, 2, "upgrade"):
        try:
            with open(os.path.join(runs, name, "stage-%s.json" % stage)) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        print("\t".join(clean(x) for x in (name, stage, d.get("result"), d.get("exit"), d.get("ref"), d.get("commit"), d.get("started"), d.get("ended"))))
PY
)
  if $list; then [ -z "$rows" ] || printf '%s\n' "$rows"; exit 0; fi
  if [ -z "$rows" ]; then note "No test-lab run yet. Start one with: hs testlab run"; exit 0; fi
  { thead 'Run' 'Stage' 'Result' 'Exit' 'Ref' 'Commit' 'Started' 'Ended'; printf '%s\n' "$rows"; } | table
  exit 0
fi

# ---------------------------------------------------------------- run
ref=develop; stage=all; from=; dry=false; yes=false; bg=ask
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) [ $# -ge 2 ] || usage; ref=$2; shift 2 ;;
    --stage) [ $# -ge 2 ] || usage; stage=$2; shift 2 ;;
    --from) [ $# -ge 2 ] || usage; from=$2; shift 2 ;;
    --dry-run) dry=true; shift ;;
    --yes) yes=true; shift ;;
    --background) bg=yes; shift ;;
    --foreground) bg=no; shift ;;
    *) usage ;;
  esac
done
case "$stage" in 1|2|all|upgrade) ;; *) usage ;; esac
[ -z "$from" ] || [ "$stage" = upgrade ] || usage
[ -z "$from" ] || [[ "$from" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_fix "The release '$from' is not accepted." "use a release tag like v0.1.0"
testlab_ref_ok "$ref" || fail_fix "The ref '$ref' is not accepted." "use a branch, a tag or a commit of the Hobnix repository (never refs/pull/...)"
testlab_url_ok "$repo_url" || fail_fix "The repository address is not on the allowlist." "only https://github.com/hobnix/<repository> is fetched"
nested_stage=all; [ "$stage" != 1 ] || nested_stage=iso
keep=${HS_TESTLAB_KEEP:-14}; [[ "$keep" =~ ^[0-9]{1,4}$ ]] || keep=14

step "$(t 'Plan: test-lab run of %s' "$ref")"
kv "Repository" "$repo_url"
kv "Ref" "$ref"
if [ "$stage" = upgrade ]; then
  kv "Stage" "upgrade (install the last release, update to $ref, check)"
  kv "From release" "${from:-the newest vX.Y.Z tag}"
  note "1. fetch the candidate $ref (it holds the harness) and the release tag"
  note "2. check that this machine can run nested VMs (KVM, Incus)"
  note "3. build the installer ISO of the RELEASE (nix, long)"
  note "4. install it in a throwaway VM, set up a share and an app, run hs update to $ref, check health, shares, state.db and the app"
  note "5. delete the VM; write stage-upgrade.json to $state/runs/<run-id>/"
  note "A failure sends a push message. Not tested on hardware yet."
  $dry && { note "Dry run: nothing was fetched, built or started."; exit 0; }
fi
kv "Stages" "$([ "$stage" = 1 ] && echo '1 (the ISO boots and installs unattended)' || echo '1 (install) and 2 (first boot and smoke check)')"
note "1. fetch the ref from the Hobnix repository (shallow, into $state/src)"
note "2. check that this machine can run nested VMs (KVM, Incus)"
note "3. build the installer ISO (nix, can take a long time and needs tens of GiB)"
note "4. $([ "$stage" = 1 ] && echo 'boot the ISO in a throwaway VM and install unattended' || echo 'install in a throwaway VM, boot the result and run the smoke check')"
note "5. delete the VM; write the result per stage to $state/runs/<run-id>/"
note "A failure sends a push message. Not tested on hardware yet."
if $dry && [ "$stage" != upgrade ]; then note "Dry run: nothing was fetched, built or started."; exit 0; fi

if ! $yes && [ -z "${HS_CALLER:-}" ]; then
  interactive || fail "Nothing is started without --yes when there is no terminal."
  warn "This builds an installer image and boots virtual machines: it takes a long time and puts load on this server."
  confirm "Run the test-lab now?" || fail "cancelled"
fi

if [ "${HS_CALLER:-}" != job ] && [ "$bg" != no ]; then
  if [ "$bg" = ask ] && interactive && confirm "Run it as a background job (you can close the terminal)?"; then bg=yes; fi
  if [ "$bg" = yes ]; then
    unit=$(hs_job testlab "hs testlab run $ref" -- bash "$here/testlab.sh" run --ref "$ref" --stage "$stage" ${from:+--from "$from"} --yes --foreground) || exit 1
    ok "$(t 'Started as job %s.' "$unit")"
    next_step "hs job follow $unit"
    exit 0
  fi
fi

# ---- the run itself (foreground, or inside the job)
mkdir -p "$state/runs" "$state/src"
exec 9>"$state/lock"
flock -n 9 || fail "Another test-lab run is going on (the lock $state/lock is held)."
runid=$(date +%Y%m%d-%H%M%S)
rundir=$state/runs/$runid
mkdir -p "$rundir"
exec > >(tee -a "$rundir/run.log") 2>&1
vm=hs-testlab-$runid
src=$state/src
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=-
nrc=0
payload() { printf '{"ref":"%s","stage":"%s"}' "$ref" "$1"; }
cleanup() {
  "$incus" delete -f "$vm" >/dev/null 2>&1 || true   # nested.sh deletes it too; this is for an interrupted run
  rm -f "$src/result-iso" 2>/dev/null || true       # the ISO is a store path: let the next garbage collection free it
  # keep the last runs only
  local old; old=$(ls -1 "$state/runs" 2>/dev/null | sort | head -n "-$keep" || true)
  [ -z "$old" ] || while IFS= read -r d; do rm -rf "${state:?}/runs/${d:?}"; done <<<"$old"
}
trap cleanup EXIT

write_stage() {   # write_stage <1|2> <ok|failed|skipped|error> <exit>
  python3 -I - "$rundir/stage-$1.json" "$runid" "$1" "$2" "$3" "$ref" "$commit" "$started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, sys
f, run, stage, result, rc, ref, commit, started, ended = sys.argv[1:10]
stage = int(stage) if stage.isdigit() else stage
with open(f, "w") as fh:
    json.dump({"run": run, "stage": stage, "result": result, "exit": int(rc), "ref": ref, "commit": commit,
               "started": started, "ended": ended}, fh, indent=1)
PY
}
fail_run() {   # fail_run <exit> <stage> <text>: an infrastructure problem before a stage ran
  local rc=$1 st=$2 txt=$3 res=error
  [ "$rc" -ne 3 ] || res=skipped
  if [ "$stage" = upgrade ]; then write_stage upgrade "$res" "$rc"; else write_stage 1 "$res" "$rc"; [ "$stage" = 1 ] || write_stage 2 "$res" "$rc"; fi
  warn "$txt"
  finish "$rc" "$st" "$txt"
}
finish() {   # finish <exit> <stage> <text>
  local rc=$1 st=$2 txt=$3
  case "$rc" in
    0) event_emit testlab.ok "$runid" "test-lab passed on $ref" --payload "$(payload all)" ;;
    3) event_emit testlab.skipped "$runid" "test-lab could not run here: $txt" --payload "$(payload "$st")" ;;
    *) event_emit testlab.failed "$runid" "test-lab failed at stage $st on $ref" --payload "$(payload "$st")"
       bash "${HS_NOTIFY:-$here/notify.sh}" --category problem "Test-lab failed" "Stage $st of the test-lab run on $ref failed: $txt. Log: $rundir/run.log" >/dev/null 2>&1 || true ;;
  esac
  exit "$rc"
}
stopped() {   # a cancelled job stops cleanly at a step border
  if hs_job_cancelled; then warn "The job was cancelled."; if [ "$stage" = upgrade ]; then write_stage upgrade skipped 130; else write_stage 1 skipped 130; [ "$stage" = 1 ] || write_stage 2 skipped 130; fi; exit 130; fi
}

event_emit testlab.started "$runid" "test-lab started on $ref" --payload "$(payload "$stage")"

hs_job_step 1 4 "Fetching $ref"; hs_job_progress 0 4 steps
step "$(t 'Fetching %s' "$ref")"
command -v "$git" >/dev/null 2>&1 || fail_run 4 1 "git is not installed"
# the global and system git configuration (insteadOf rewrites, credential helpers) is not read; only https is allowed
gitc() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 "$git" -c protocol.allow=never -c protocol.https.allow=always -c core.hooksPath=/dev/null "$@"; }
if [ ! -d "$src/.git" ]; then gitc -C "$src" init -q || fail_run 4 1 "git init failed"; fi
gitc -C "$src" remote remove origin >/dev/null 2>&1 || true
gitc -C "$src" remote add origin "$repo_url" || fail_run 4 1 "git remote failed"
gitc -C "$src" fetch -q --depth 1 origin "$ref" || fail_run 4 1 "could not fetch $ref from $repo_url"
gitc -C "$src" checkout -q -f --detach FETCH_HEAD || fail_run 4 1 "could not check out $ref"
gitc -C "$src" clean -q -fdx -e .work -e result-iso >/dev/null 2>&1 || true
commit=$(gitc -C "$src" rev-parse HEAD 2>/dev/null || echo -)
ok "$(t 'Checked out %s' "$commit")"
stopped

hs_job_step 2 4 "Checking that nested VMs can run"; hs_job_progress 1 4 steps
step "$(t 'Run %s: can this machine run nested VMs?' "$runid")"
[ -f "$src/scripts/dev/nested.sh" ] && [ -f "$src/scripts/dev/build-iso.sh" ] || fail_run 4 1 "this ref has no scripts/dev/nested.sh or build-iso.sh"
if ! bash "$src/scripts/dev/nested.sh" preflight; then fail_run 3 1 "this machine cannot run nested VMs (no KVM, nested virtualization or incus)"; fi
stopped

if [ "$stage" = upgrade ]; then
  # ---- the upgrade stage: the harness is the one of the candidate (src), the ISO is the one of the last release (src-old)
  hs_job_step 3 4 "Building the ISO of the last release"; hs_job_progress 2 4 steps
  old=$state/src-old
  if [ -z "$from" ]; then
    from=$(gitc ls-remote --tags --refs "$repo_url" 'v*' 2>/dev/null | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
    [ -n "$from" ] || { write_stage upgrade skipped 3; warn "no release tag (vX.Y.Z) exists yet: nothing to upgrade from"; finish 3 upgrade "no release to upgrade from"; }
  fi
  note "$(t 'Upgrading from %s to %s' "$from" "$ref")"
  mkdir -p "$old"
  [ -d "$old/.git" ] || gitc -C "$old" init -q || { write_stage upgrade error 4; finish 4 upgrade "git init failed"; }
  gitc -C "$old" remote remove origin >/dev/null 2>&1 || true
  gitc -C "$old" remote add origin "$repo_url"
  if ! gitc -C "$old" fetch -q --depth 1 origin "refs/tags/$from"; then write_stage upgrade error 4; finish 4 upgrade "could not fetch the release $from"; fi
  gitc -C "$old" checkout -q -f --detach FETCH_HEAD || { write_stage upgrade error 4; finish 4 upgrade "could not check out $from"; }
  gitc -C "$old" clean -q -fdx -e result-iso >/dev/null 2>&1 || true
  if ! (cd "$old" && SPIN_STREAM=1 timeout "${HS_TESTLAB_BUILD_TIMEOUT:-5400}" bash scripts/dev/build-iso.sh); then write_stage upgrade error 4; finish 4 upgrade "the ISO build of $from failed (see run.log)"; fi
  oldiso=$(ls "$old"/result-iso/iso/*.iso 2>/dev/null | head -n 1 || true)
  [ -n "$oldiso" ] || { write_stage upgrade error 4; finish 4 upgrade "the ISO of $from is missing after the build"; }
  stopped
  hs_job_step 4 4 "Install $from, update to $ref"; hs_job_progress 3 4 steps
  nrc=0
  (cd "$src" && timeout "${HS_TESTLAB_RUN_TIMEOUT:-2700}" bash scripts/dev/nested.sh run --stage upgrade --iso "$oldiso" --candidate "$ref" --name "$vm") || nrc=$?
  ndir=$(cd "$src/.work/nested/latest" 2>/dev/null && pwd || true)
  [ -z "$ndir" ] || cp -r "$ndir" "$rundir/harness" 2>/dev/null || true
  [ -z "$ndir" ] || rm -f "$rundir/harness/key" "$rundir/harness/password"
  ur=error
  if [ -n "$ndir" ] && [ -f "$ndir/result-upgrade.json" ]; then
    ur=$(python3 -I -c 'import json,sys; print("ok" if json.load(open(sys.argv[1])).get("ok") else "failed")' "$ndir/result-upgrade.json" 2>/dev/null || echo error)
  elif [ "$nrc" = 1 ]; then ur=failed   # the install stage failed: no upgrade could run
  elif [ "$nrc" = 3 ]; then ur=skipped; fi
  write_stage upgrade "$ur" "$nrc"
  hs_job_progress 4 4 steps
  step "$(t 'Result')"
  status_line "Upgrade $from to $ref" "$ur" "$([ "$ur" = ok ] && echo ok || echo bad)"
  note "$(t 'Commit %s, run folder %s' "$commit" "$rundir")"
  case "$ur" in ok) finish 0 upgrade "" ;; failed) finish 1 upgrade "the upgrade from $from failed" ;; skipped) finish 3 upgrade "the harness cannot run here" ;; *) finish 4 upgrade "upgrade $ur" ;; esac
fi

hs_job_step 3 4 "Building the installer ISO"; hs_job_progress 2 4 steps
step "$(t 'Building the installer ISO (this takes a long time)')"
if ! (cd "$src" && SPIN_STREAM=1 timeout "${HS_TESTLAB_BUILD_TIMEOUT:-5400}" bash scripts/dev/build-iso.sh); then fail_run 4 2 "the ISO build failed (see run.log)"; fi
stopped

hs_job_step 4 4 "Running the nested harness (stage $([ "$stage" = 1 ] && echo 1 || echo '1 and 2'))"; hs_job_progress 3 4 steps
step "$(t 'Running the nested harness, VM %s' "$vm")"
nrc=0
(cd "$src" && timeout "${HS_TESTLAB_RUN_TIMEOUT:-2700}" bash scripts/dev/nested.sh run --stage "$nested_stage" --name "$vm") || nrc=$?
ndir=$(cd "$src/.work/nested/latest" 2>/dev/null && pwd || true)
[ -z "$ndir" ] || cp -r "$ndir" "$rundir/harness" 2>/dev/null || true
[ -z "$ndir" ] || rm -f "$rundir/harness/key" "$rundir/harness/password"   # a throwaway key and password of the VM: not kept

stage_res() {   # stage_res <iso|smoke>: ok|failed|skipped|error from the harness result file, else from its exit code
  local f=$ndir/result-$1.json
  if [ -n "$ndir" ] && [ -f "$f" ]; then
    python3 -I -c 'import json,sys; print("ok" if json.load(open(sys.argv[1])).get("ok") else "failed")' "$f" 2>/dev/null || echo error
    return
  fi
  case "$nrc" in 0) echo ok ;; 3) echo skipped ;; *) echo error ;; esac
}
r1=$(stage_res iso)
write_stage 1 "$r1" "$nrc"
if [ "$stage" = 1 ]; then r2=-; else
  if [ "$r1" = ok ]; then r2=$(stage_res smoke); else r2=skipped; fi   # no installed system without stage 1
  write_stage 2 "$r2" "$nrc"
fi
hs_job_progress 4 4 steps

step "$(t 'Result')"
status_line "Stage 1" "$r1" "$([ "$r1" = ok ] && echo ok || echo bad)"
[ "$r2" = - ] || status_line "Stage 2" "$r2" "$([ "$r2" = ok ] && echo ok || echo bad)"
note "$(t 'Commit %s, run folder %s' "$commit" "$rundir")"

if [ "$r1" = ok ] && { [ "$r2" = ok ] || [ "$r2" = - ]; }; then finish 0 all ""; fi
if [ "$r1" = skipped ]; then finish 3 1 "the harness cannot run here"; fi
if [ "$r1" != ok ]; then finish "$([ "$r1" = failed ] && echo 1 || echo 4)" 1 "stage 1 $r1"; fi
finish "$([ "$r2" = failed ] && echo 1 || echo 4)" 2 "stage 2 $r2"
