#!/usr/bin/env bash
# The Rust extension SDK (rust/hobnix-ext-sdk, issue #240): its two example extensions built with cargo and driven by the reference
# runners of the protocols (scripts/lib/ext_proto.py for commands, ADR 0010; scripts/lib/ext_service.py for services, ADR 0011).
# The SDK's own unit tests are `cargo test -p hobnix-ext-sdk` (CI runs them). Skipped (77) without cargo or python3, or off Linux.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
command -v cargo >/dev/null || { echo "  skip  cargo missing"; exit 77; }
command -v python3 >/dev/null || { echo "  skip  python3 missing"; exit 77; }
[ "$(uname -s)" = Linux ] || { echo "  skip  needs Linux"; exit 77; }
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/rust/target}
if ! (cd "$ROOT/rust" && cargo build --locked -q -p hobnix-ext-sdk --examples) > "$WORK/build.log" 2>&1; then
  # most likely no network for the crates, or a toolchain older than rust-toolchain.toml wants: not this test's business
  if grep -q -E "failed to (get|download)|Could not resolve|unable to update registry|network" "$WORK/build.log"; then echo "  skip  crates not available (offline)"; exit 77; fi
  fail "cargo build of the examples: $(tail -n 5 "$WORK/build.log" | tr '\n' ' ')"; finish; exit
fi
EX=$CARGO_TARGET_DIR/debug/examples
RUN="python3 -I $SCRIPTS/lib/ext_proto.py"

echo "-- command example"
rc=0; out=$($RUN call --command greet --arg Ada -- "$EX/hello" 2>&1) || rc=$?
check_eq "greet exits 0" 0 "$rc"
check_out "greet answers with data" '"greeting":"hello Ada"' printf '%s' "$out"
check_out "greet passes the event on" 'pkg.hello.greeted' printf '%s' "$out"
rc=0; out=$($RUN call --command count --arg 99 -- "$EX/hello" 2>&1) || rc=$?
check_eq "a bad argument is a failure with exit 1" 1 "$rc"
check_out "with the code bad_request" '"code":"bad_request"' printf '%s' "$out"
rc=0; out=$($RUN call --command nosuch -- "$EX/hello" 2>&1) || rc=$?
check_out "an unknown command is not_found, not a protocol error" '"code":"not_found"' printf '%s' "$out"

echo "-- service example"
rc=0; out=$(python3 -I "$SCRIPTS/lib/ext_service.py" run --name ticker --health-interval 1 --run-for 2.5 -- "$EX/ticker" 2>&1) || rc=$?
check_eq "the service runs and stops cleanly" 0 "$rc"
check_out "it publishes snapshots" '"topic":"ticks"' printf '%s' "$out"
check_out "it ends in the state stopped" '"final","state":"stopped"' printf '%s' "$out"
finish
