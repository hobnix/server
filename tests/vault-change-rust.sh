#!/usr/bin/env bash
# tests/vault-change.sh, unchanged, against the Rust implementation of hs sys secrets plan|start (rust:secrets, docs/adr/0001-rust-strangler.md),
# then the shell script and the binary side by side: stdout, stderr, exit code and the started jobs must be the same for every input.
# The binary: HOBNIX_BIN, else rust/target/debug|release/hobnix (cargo build in rust/). Without one, or off Linux, the test is skipped (77).
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${HOBNIX_BIN:-}
if [ -z "$bin" ]; then
  [ "$(uname -s)" = Linux ] || { echo "  skip  needs Linux (WSL) or HOBNIX_BIN"; exit 77; }
  for c in "$root/rust/target/debug/hobnix" "$root/rust/target/release/hobnix"; do [ -x "$c" ] && { bin=$c; break; }; done
fi
[ -n "$bin" ] && [ -x "$bin" ] || { echo "  skip  no hobnix binary (cargo build in rust/, or HOBNIX_BIN)"; exit 77; }
# shellcheck source=tests/lib.sh
. "$root/tests/lib.sh"
unset HOBNIX_LOG HS_CALLER HS_GUIDED_TTY
shim() {   # shim <file>: what hs does for a rust:secrets row (HS_SCRIPTS = the folder of the file)
  printf '#!/usr/bin/env bash\nHS_SCRIPTS=$(cd "$(dirname "$0")" && pwd) exec "%s" secrets "$@"\n' "$bin" > "$1"
}

echo "-- tests/vault-change.sh against the binary"
tree=$WORK/tree; mkdir -p "$tree/tests" "$tree/scripts/lib"
cp "$root/tests/lib.sh" "$root/tests/vault-change.sh" "$tree/tests/"
cp "$root/scripts/lib/"*.sh "$tree/scripts/lib/"
shim "$tree/scripts/vault-change.sh"
if bash "$tree/tests/vault-change.sh" > "$WORK/unchanged.log" 2>&1; then pass "tests/vault-change.sh passes against Rust"
else fail "tests/vault-change.sh against Rust: $(grep FAIL "$WORK/unchanged.log" | head -n 5 | tr '\n' ' ')"; fi

echo "-- shell and Rust give the same answer"
T=$'\t'
cat > "$WORK/vault.sh" <<FAKE
#!/usr/bin/env bash
case "\$1" in usage) [ "\$HS_VAULT_STATE" = none ] || printf 'state${T}%s\n' "\$HS_VAULT_STATE" ;; esac
FAKE
cp "$WORK/vault.sh" "$WORK/secrets.sh"
export HS_VAULT=$WORK/vault.sh HS_SECRETS=$WORK/secrets.sh HS_PLAIN=1 HS_LANG=en
for d in sh rs; do
  mkdir -p "$WORK/$d/lib"; : > "$WORK/$d.jobs"
  printf 'hs_job() { echo "JOB $*" >> "%s"; echo hs-job-test-1; }\n' "$WORK/$d.jobs" > "$WORK/$d/lib/job.sh"
done
cp "$SCRIPTS/vault-change.sh" "$WORK/sh/vault-change.sh"
shim "$WORK/rs/vault-change.sh"
cases=("" "plan" "bogus|header-backup" "plan|init" "plan|bind|a|b" "start|init"
  "plan|header-backup" "plan|header-backup|extra" "plan|move" "plan|move|restic-password" "plan|move|a|b.c_d-e" "plan|move|a b" "plan|move|-x"
  "plan|close" "plan|close|--bogus" "plan|close|--confirm" "plan|close|--confirm|close" "plan|secrets-fix" "plan|secrets-fix|x"
  "start|header-backup" "start|move|restic-password" "start|close" "start|close|--confirm|nope" "start|close|--confirm|close"
  "start|close|--confirm|close|--confirm|nope" "start|secrets-fix")
for st in open closed none; do
  export HS_VAULT_STATE=$st
  for c in "${cases[@]}"; do
    a=(); [ -z "$c" ] || IFS='|' read -ra a <<<"$c"
    for d in sh rs; do
      rc=0; timeout 20 bash "$WORK/$d/vault-change.sh" ${a[@]+"${a[@]}"} </dev/null >"$WORK/$d.out" 2>"$WORK/$d.err" || rc=$?
      echo "$rc" > "$WORK/$d.rc"
    done
    if cmp -s "$WORK/sh.out" "$WORK/rs.out" && cmp -s "$WORK/sh.err" "$WORK/rs.err" && cmp -s "$WORK/sh.rc" "$WORK/rs.rc"; then
      pass "same: $st ${c//|/ }"
    else
      fail "differs: $st '${c//|/ }': shell rc $(cat "$WORK/sh.rc") [$(tr '\t\n' '> ' <"$WORK/sh.out")] rust rc $(cat "$WORK/rs.rc") [$(tr '\t\n' '> ' <"$WORK/rs.out")] $(head -c 200 "$WORK/rs.err")"
    fi
  done
done
if cmp -s "$WORK/sh.jobs" "$WORK/rs.jobs"; then pass "the same jobs, with the same words"; else fail "jobs differ: $(diff "$WORK/sh.jobs" "$WORK/rs.jobs" | head -n 6 | tr '\n' ' ')"; fi
finish
