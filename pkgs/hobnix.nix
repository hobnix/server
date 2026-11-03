# The Rust part of the core (rust/, docs/adr/0001-rust-strangler.md): the `hobnix` program that registry rows named rust:<subcommand> run.
# Locked dependencies, built offline. After changing a dependency in rust/Cargo.toml refresh rust/Cargo.lock (cargo update, commit it);
# crates from crates.io need no extra hash here because cargoLock.lockFile pins them by checksum.
{ rustPlatform, lib }:

rustPlatform.buildRustPackage {
  pname = "hobnix";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../rust;
    filter = path: type: baseNameOf path != "target";
  };
  cargoLock.lockFile = ../rust/Cargo.lock;

  # cargo test of the workspace runs in the check phase
  meta.mainProgram = "hobnix";
}
