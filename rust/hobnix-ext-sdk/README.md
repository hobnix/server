# hobnix-ext-sdk

Rust SDK for Hobnix extensions (epic #197, issue #240). It is the extension side of two protocols, so an extension in Rust does not
hand-write JSON lines:

| Kind | Module | Protocol | Schema |
| --- | --- | --- | --- |
| Command extension (one process per call) | `command` | [ADR 0010](../../docs/adr/0010-extension-command-protocol.md) | `docs/api/ext-protocol-v1.schema.json` |
| Service extension (one supervised process) | `service` | [ADR 0011](../../docs/adr/0011-extension-service-lifecycle.md) | `docs/api/ext-service-v1.schema.json` |

Status: both ADRs are Proposed and `hs` does not call extensions through the protocol yet (their follow-ups). The SDK speaks version 1
as the ADRs and schemas define it and is tested against the reference runners, not against `hs`.

## A command extension

```rust
use hobnix_ext_sdk::command::{run, Failure, Success};
use std::process::ExitCode;

fn main() -> ExitCode {
    run(|req, ctx| match req.words().as_slice() {
        ["greet"] => {
            ctx.progress(Some(0.5), "thinking").ok();
            Ok(Success::text(format!("hello {}", req.argv.join(" "))))
        }
        _ => Err(Failure::not_found("no such command")),
    })
}
```

`run` reads the one request line, answers `unsupported_version` for a `v` it does not know, calls your closure, and writes exactly one
`result` (exit status 0 for `ok`, 1 otherwise). A panic becomes `failed`. `Ctx` sends `progress`, `log` and `event` messages; free
text is cut to the schema limits and an event kind that is not `pkg.<package>.<kind>` is refused before it is written. The example is
`examples/hello.rs`.

## A service extension

Implement `service::Service` (`start`, `on_event`, `tick`, all optional) and call `service::run(MyService)`. The SDK sends `ready`
after `start`, calls `tick` and sends `health` every half `health_interval`, sends the `ack` after `on_event` returns `Ok`, and
returns on `shutdown` or end of stdin. Delivery is at least once: `on_event` must be idempotent (key: `EventRow::id`). `Ctx` is
`Clone + Send` and offers `log`, `emit` and `snapshot`. The example is `examples/ticker.rs`.

## Rules for the author

- **stdout is the protocol.** Never `println!`; diagnostics go to stderr (kept by the core on failure, or in the journal for a service).
- **No secrets** in `argv`, `data`, snapshots or logs (ADR 0010 rule 9).
- **Cancel and timeout are SIGTERM** to the process group, then SIGKILL after the grace time. The SDK installs no signal handler (it
  would need `unsafe` or a crate); the default action ends the process, which is a valid answer within the rules. A command that
  needs cleanup can add its own handler and send `ErrorCode::Cancelled`.
- A slow `on_event` or `tick` delays the heartbeat; do long work on your own threads.
- Shape of `data` is yours, per command; the core renders it (ADR 0010 open point).

## Build and test

```bash
cd rust
cargo test -p hobnix-ext-sdk                    # unit tests: wire format in memory, no processes
cargo build -p hobnix-ext-sdk --examples
python3 -I ../scripts/lib/ext_proto.py call --command greet --arg Ada -- "$PWD/target/debug/examples/hello"
bash ../scripts/dev/t quick ext-sdk-rust        # the examples against both reference runners; skipped without cargo
```

An extension package that uses the SDK depends on it by path or git (`publish = false`, nothing is on crates.io), and ships its
binary built for the server; building on the server is not part of the package contract yet. Not tested on hardware yet.
