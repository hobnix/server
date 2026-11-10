#!/usr/bin/env bash
# help: start the test-lab without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: das Testlabor starten, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob (start)
# args: plan|start run [--ref <branch|tag|commit>] [--stage 1|2|all]
# System command (hs sys testlab plan|start): for the interface and tests. It never asks and prints plain key<TAB>value lines like admin-change.sh.
# The work is scripts/testlab.sh's (checks of ref and repository are its own and are repeated here before the job starts).
# plan: exit 0 = allowed, 1 = refused. Output: status ok|refused, reason<TAB><text>, heading|step|note|warn|command<TAB><line>, long<TAB>yes.
# start: the same checks, then a background job: status started + unit. UNVERIFIED: not tested on hardware yet.
# Test knobs: HS_TESTLAB (stand-in for testlab.sh), HS_TESTLAB_REPO.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: testlab-change.sh plan|start run [--ref <ref>] [--stage 1|2|all]" >&2; exit 1 ;; esac
[ "$action" = run ] || refuse "unknown action (run)"
shift 2 || true
ref=develop; stage=all
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) [ $# -ge 2 ] || refuse "--ref needs a value"; ref=$2; shift 2 ;;
    --stage) [ $# -ge 2 ] || refuse "--stage needs a value"; stage=$2; shift 2 ;;
    *) refuse "unknown option $1" ;;
  esac
done
case "$stage" in 1|2|all) ;; *) refuse "stage must be 1, 2 or all" ;; esac

export HS_PLAIN=1 HS_LANG=en HS_CALLER=${HS_CALLER:-ui}
unset HS_GUIDED_TTY
. "$here/lib/capability.sh"
capability_on testlab || refuse "The test-lab is off (capability testlab)."
# the same rules as testlab.sh: a dry run of it refuses a ref or repository that is not allowed
bash "${HS_TESTLAB:-$here/testlab.sh}" run --ref "$ref" --stage "$stage" --dry-run >/dev/null 2>&1 </dev/null || refuse "That ref or repository is not accepted (only branches, tags and commits of the Hobnix repositories)."

if [ "$verb" = start ]; then
  . "$here/lib/job.sh"
  unit=$(hs_job testlab "hs testlab run $ref" -- bash "${HS_TESTLAB:-$here/testlab.sh}" run --ref "$ref" --stage "$stage" --yes --foreground) || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi
printf 'status\tok\nheading\trun the test-lab on %s\n' "$ref"
printf 'step\tfetch %s from the Hobnix repository and build the installer ISO\n' "$ref"
if [ "$stage" = 1 ]; then printf 'step\tboot the ISO in a throwaway VM and install it unattended (stage 1)\n'
else printf 'step\tinstall in a throwaway VM, boot the result and run the smoke check (stages 1 and 2)\n'; fi
printf 'step\tdelete the VM; keep the result per stage\n'
printf 'note\tIt takes a long time and loads the server. A failure sends a push message. Not tested on hardware yet.\n'
printf 'command\ths testlab run --ref %s --stage %s\nlong\tyes\n' "$ref" "$stage"
