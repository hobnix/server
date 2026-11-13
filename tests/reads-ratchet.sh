#!/usr/bin/env bash
# scripts/dev/reads-inventory.py --check: every read has a topic or a reason, timed polls only go down. A tiny fixture, then the real tree.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
INV=$ROOT/scripts/dev/reads-inventory.py
FX=$WORK/fx
mkdir -p "$FX/src/pages"
cat > "$FX/serve.py" <<'X'
NAME = r"^x$"
READS = {
    ("status",): {"kind": "tsv", "ttl": 10, "topic": "status"},
    ("pool", "info"): {"kind": "tsv", "ttl": 15, "query": {"pool": (NAME, "")}, "topic": {"bulk": "a", "fast": "b"}},
    ("ct", "logs"): {"kind": "text", "ttl": 3, "args": [NAME]},
    ("release", "show"): {"kind": "tsv", "ttl": 30},
}
X
cat > "$FX/src/pages/A.svelte" <<'X'
<script>
  // const old = poll('/api/sys/release/show', 1000);
  const a = poll('/api/sys/status', 5000);
  const b = poll('/api/sys/release/show', 5000, 'release');
  const c = poll(() => (x ? `/api/sys/ct/logs/${name}` : ''), 5000);
  const d = poll('/api/sys/pool/info?pool=bulk', 5000);
  const e = poll(PATH, 5000);
  const f = poll('/api/sys/release/show', 5000, undefined);
  const CH = '/api/sys/status';
  const g = poll(CH, 5000);
  const h = poll('/api/sys/status?x=1', 5000);
  const i = poll('/api/sys/pool/info?pool=other', 5000);
</script>
X
printf 'ct logs\tfree argument: one container\ndynamic:pages/A.svelte\tpath is a constant\nrelease show\tre-read after a change\nstatus\tx\npool info\tx\n' > "$FX/reasons.tsv"
echo 5 > "$FX/max"
run() { python3 "$INV" --root "$FX/src" --serve "$FX/serve.py" --reasons "$FX/reasons.tsv" --max "$FX/max" "$@"; }

run --check >/dev/null 2>&1; check_eq "fixture passes" 0 "$?"
check_out "tsv: explicit-topic poll is live" $'poll\trelease show\tpages/A.svelte:4\texplicit\t-' run --tsv
check_out "tsv: map-topic poll is live" $'poll\tstatus\tpages/A.svelte:3\tmap\t-' run --tsv
check_out "tsv: pool info (topic map) is live" $'poll\tpool info\tpages/A.svelte:6\tmap\t-' run --tsv
check_out "tsv: timed poll has its reason" $'poll\tct logs\tpages/A.svelte:5\t-\tfree argument: one container' run --tsv
check_out "tsv: dynamic key" $'poll\tdynamic:pages/A.svelte\tpages/A.svelte:7\t-\tpath is a constant' run --tsv
check_out "tsv: null/undefined third argument is timed" $'poll	release show	pages/A.svelte:8	-	re-read after a change' run --tsv
check_out "tsv: poll(CH) resolves the const of the file (live)" $'poll	status	pages/A.svelte:10	map	-' run --tsv
check_out "tsv: topic read with a query is timed" $'poll	status	pages/A.svelte:11	-	x' run --tsv
check_out "tsv: pool other than bulk/fast is timed" $'poll	pool info	pages/A.svelte:12	-	x' run --tsv
check_eq "tsv: a poll in a comment is not a call" 0 "$(run --tsv | grep -c 'A.svelte:2')"

echo 6 > "$FX/max"
check_out "count below max fails" 'went down: lower the number to 5' run --check
echo 4 > "$FX/max"
check_out "count above max names the count" 'went up: 5 calls' run --check
run --check >/dev/null 2>&1; check_eq "count above max exits 1" 1 "$?"
echo 5 > "$FX/max"

printf 'ct logs\tx\ndynamic:pages/A.svelte\tx\nstatus\tx\npool info\tx\n' > "$FX/reasons.tsv"
check_out "READS entry without topic and reason fails, names it" 'no reason.*: release show' run --check
printf 'release show\tx\ndynamic:pages/A.svelte\tx\nstatus\tx\npool info\tx\n' > "$FX/reasons.tsv"
check_out "timed poll without reason fails, names it" 'no reason.*: ct logs' run --check
printf 'ct logs\tx\nrelease show\tx\nstatus\tx\npool info\tx\n' > "$FX/reasons.tsv"
check_out "dynamic poll without reason fails" 'no reason.*: dynamic:pages/A.svelte' run --check
printf 'ct logs\tx\nrelease show\tx\ndynamic:pages/A.svelte\tx\nstatus\tx\npool info\tx\nsnap\tx\n' > "$FX/reasons.tsv"
check_out "stale reason fails" 'stale reason.*: snap' run --check
printf 'ct logs\tx\nrelease show\tx\ndynamic:pages/A.svelte\tx\nstatus\tx\npool info\tx\n' > "$FX/reasons.tsv"
run --check >/dev/null 2>&1; check_eq "fixed again passes" 0 "$?"

python3 "$INV" --check >/dev/null 2>&1; check_eq "real tree passes" 0 "$?"
check_out "real tree lists reads" '^read	status	' python3 "$INV" --tsv
finish
