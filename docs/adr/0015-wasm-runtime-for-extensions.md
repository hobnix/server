# 0015: WebAssembly for extension scripts: defer, keep the protocol transport-neutral

Status: Proposed
Issue: hobnix/server#266 (epic #197). Related: ADR 0010 (command protocol, #237), ADR 0011 (service lifecycle, #238), ADR 0014 (permissions, #239), Rust SDK #240.

This is a research record. The recommendation is "defer, with named triggers". Nothing in it was run on a NixOS host: the size and build
numbers the issue asks for are **not measured** and are listed as the first task of a spike, below.

## Context (checked 2026-11-08 on develop)

- An extension command is a script that runs **as root** (docs/PLAN-extensions.md "Security"). Installing a package is trusting its author; the
  controls are signed tags and the update diff (ADR 0008 rules 5 and 6). Today every package lives in a repository the owner reviews.
- ADR 0010 already lets a command be any executable that reads one JSON line on stdin and writes JSON Lines on stdout. That contract does not
  mention shell: it is a process boundary.
- ADR 0014 lists the permission vocabulary (`fs.*`, `net`, `host`, `secrets`, `events.*`) and four mechanisms. Its recommendation: declare and
  disclose (step 1), systemd confinement for services (step 2), an unprivileged user plus a **command broker** only if third-party packages
  become a goal (step 3). The broker is the only part that enforces `host` and `secrets`.
- Hobnix constraints: NixOS on a small home server (little RAM, often an old CPU), **no Node on the server**, the web interface declarative
  (PLAN-extensions "The web declaration"), shell and Python as the glue language, Rust growing behind `hs sys` (ADR 0001).
- The question: can an extension ship a `.wasm` module so third parties write logic in Rust, Go or Zig "without raw host binaries"?

## What Wasm would and would not give

A Wasm module sees only what the host hands it. With WASI, the host chooses preopened directories, environment, stdio and (in preview 2)
sockets; everything else is a host function the runtime author writes. Two consequences:

- **It confines files and network without a Unix user or systemd unit.** That is the part ADR 0014 steps 2 and 3 do with `ProtectSystem=`,
  `ReadWritePaths=`, `IPAddressAllow=` and `User=hs-ext-<name>`. Wasm makes the same grant a property of the runtime call.
- **It does not remove the need for a broker.** An extension exists to *do something to the host*: `incus`, `systemctl`, an `hs` command, a
  secret. A module cannot run those; the runtime must expose them as host functions (or the module returns "please run X" and the core runs it).
  That layer checks `host`, `secrets` and `events.emit` against the manifest, which is exactly ADR 0014's broker. So Wasm does not replace step 3;
  it replaces only the "run the package as another Unix user" half of it.

## Options

| | A. Process + permissions (ADR 0014 steps 1-3) with the Rust SDK (#240) | B. Wasm module run by wasmtime (CLI or embedded) | C. Wasm through Extism | D. Wasmer |
| --- | --- | --- | --- | --- |
| Language of the extension | anything that makes an executable; the SDK is Rust | anything that compiles to `wasm32-wasip1` or `wasip2`: Rust (tier 2 target), Go (`GOOS=wasip1`, or TinyGo), Zig, C | the same, plus Extism's plugin development kits (PDKs) per language | as B |
| Fits ADR 0010 | yes, unchanged | yes: `wasmtime run` with stdin/stdout; the JSON Lines contract needs no change | no: Extism calls exported functions with byte buffers, not stdio; a message would be wrapped by a small adapter | as B |
| File access | systemd properties or the broker | preopened directories (`--dir host::guest`), read-only or writable per mapping | `allowed_paths` map host path to guest path | preopens |
| Network | systemd `IPAddressAllow=` (owner decides what `net` means) | sockets only when granted; preview 2 defines wasi-sockets, support depends on the runtime version | **HTTP only**, and only to `allowed_hosts` (empty means none); no raw sockets | as B, support varies |
| Host calls (`incus`, `hs`, secrets) | broker over a request channel | host functions the core must write and version | host functions (the same work) | host functions |
| New things on the server | none | a runtime binary (wasmtime is a Rust crate and a nixpkgs package; the closure size is **not measured**) | the Extism library plus a host SDK in Python or Rust | a runtime binary (also in nixpkgs; size **not measured**) |
| Cold start per call | one fork/exec | compile on first use; a precompiled `.cwasm` cache avoids it, at the price of a cache tied to the runtime version | similar | similar, other backends |
| Debuggability for a package author | ordinary tools | poor: stack traces and `strace` are replaced by the runtime's own tooling | poor | poor |
| Maturity relevant to us | the least new code | WASI preview 2 and the component model are the direction of travel; interface versions are still moving (preview 3 adds async) | stable plugin ABI, active, small community compared with the runtimes under it | active |

Notes on the options:

- **Runtimes.** wasmtime (Bytecode Alliance) and wasmer are both packaged in nixpkgs; the attribute names and versions must be checked when the
  spike runs. wasmtime is the reference implementation for WASI and the component model; Extism builds on it (its docs list host SDKs for many
  languages). A smaller interpreter (wasm3, wasmi) would cost less RAM but runs slower and trails on WASI.
- **Extism's network model is narrower than WASI's.** `allowed_hosts` governs its HTTP host function; a plugin that needs a TCP or UDP socket
  (an mDNS responder, Wake-on-LAN) cannot do it there. Wake-on-LAN (the Games page has a "Wake" action) is a UDP broadcast, if that is how it is done.
- **The host side of Hobnix is shell and Python.** wasmtime has a Python binding and a CLI; the CLI is the simplest fit with ADR 0010
  (one process per call, stdio), and a service extension (ADR 0011) is the same process kept running.

## Decision

1. **Defer Wasm.** No Wasm runtime is added to the core now, no manifest key names one, and no package kind is added for it.
2. **Do the work Wasm would also need, because it is useful anyway:** the permission vocabulary and `permissions` manifest key (ADR 0014 step 1)
   and the host request channel of ADR 0010's open point. Rust SDK (#240) is built as a process that speaks ADR 0010.
3. **Keep ADR 0010 transport-neutral.** The protocol rules say "a process, one request line, JSON Lines back". Do not add any rule that
   depends on a Unix pid, a signal other than the documented SIGTERM/SIGKILL pair, an inherited file descriptor or an environment variable
   (the `lang` and `caller` fields are already in the request, not in the environment). Then `wasmtime run module.wasm` is a command that
   reads and writes the same lines, with the timeout and cancel enforced by killing the runtime process. This is a property to keep, not
   a feature to build.
4. **Revisit when one of these is true** (any one):
   a. Third-party, unreviewed packages become a goal (ADR 0014 open point 3: the owner decides that a package may be an unknown author's code);
   b. the broker exists and the remaining gap is "a package must not read arbitrary files, and a root-owned process cannot be trusted to";
   c. a package author asks to ship one binary that runs on x86_64 and aarch64 without a build per architecture (the issue's "without raw host
      binaries" is mostly this; today a package builds on the host or ships scripts).
5. **If revisited, the first candidate is B (wasmtime CLI, preview 2), not Extism**, because B keeps the ADR 0010 contract, grants sockets, and
   needs no SDK in the host languages. Extism is considered again only if the Hobnix host side moves to Rust (ADR 0001) and a plugin ABI with
   host functions is wanted for its own sake.

## Spike (the measurements this record does not have)

Run once on a NixOS host or the throwaway VM (`scripts/dev/t vm`), and attach the numbers to this record before it is accepted:
1. `nix path-info -S` (closure size) for wasmtime and wasmer from the pinned nixpkgs; resident memory of `wasmtime run` on a hello module.
2. Time for a "hello" JSON-lines extension: native Rust, wasmtime cold, wasmtime with a precompiled `.cwasm`. Test on the slowest supported box.
3. A UDP broadcast (Wake-on-LAN) from a `wasm32-wasip2` module under wasmtime: does the runtime version in nixpkgs allow it and under which flag?
4. Whether an `hs` command can be reached from the module only through a host function, and what that costs to write for three commands.

## Consequences

- Easier: no new runtime to package, update and patch on every host; ADR 0014's recommendation stays the plan; the Rust SDK work is not blocked.
- Harder: the first unreviewed package author still needs "trust the author" or the broker; there is no portable single-binary story until
  the triggers above fire.
- Follow-up (small, not a new issue): a sentence in ADR 0010's Consequences that the protocol must stay transport-neutral. This record does
  not edit ADR 0010, because a Proposed record is changed in its own pull request.

## Open points

1. Is point 4c a goal at all, or does the owner only care about confinement (then systemd plus the broker may be enough for ever)?
2. If Wasm is added later, is it a fourth package kind or a `runtime = "wasm"` field of an extension? (The second is smaller and keeps `pkg.py` kinds.)
3. Who signs and reviews a `.wasm` file? A binary blob defeats the "diff shown by `hs pkg update`" control of ADR 0008; the source or a reproducible
   build recipe would have to be part of the package.
4. Nix ties: the runtime is one more input in flake.lock; does it go through the binary cache (ADR 0003)?

## Sources

- [Wasmtime documentation](https://docs.wasmtime.dev/) and its [`wasmtime_wasi::p2` module](https://docs.wasmtime.dev/api/src/wasmtime_wasi/p2/mod.rs.html), which lists the wasi-sockets bindings (a search found no single dated status statement; check release notes for the version in nixpkgs).
- [Extism manifest schema](https://docs.rs/extism-manifest/1.12.0/src/extism_manifest/lib.rs.html) (`allowed_hosts`, `allowed_paths`) and the [Extism Go SDK](https://beta.pkg.go.dev/github.com/extism/go-sdk).
- [WASI repository](https://github.com/WebAssembly/WASI) for the preview 2 and 3 interface status.
