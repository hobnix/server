# 0003: Binary cache on Cachix, filled by CI

Status: Accepted (2026-11-10)
Issue: hobnix/server#253 (epic #121)

## Context

- The Rust program (`pkgs/hobnix.nix`, ADR 0001) is compiled on the server at every `hs rebuild` that changes it, and so is anything else
  that is not on cache.nixos.org.
- CI already builds the program in the `nixos` job (`.github/workflows/ci.yml`).
- Choice made by the owner on 2026-11-04: Cachix (hosted) instead of a self-hosted Attic. No server or storage to run; the free tier has a
  storage limit, and the cache name and keys belong to the owner's Cachix account.

## Decision

1. CI pushes what the `nixos` job builds to the cache, with `cachix/cachix-action`. It runs only when the repository variable
   `CACHIX_CACHE` is set; the push needs the secret `CACHIX_AUTH_TOKEN`. Pull requests from forks and Dependabot have no secret and only read.
2. Hosts learn the cache from `config/binary-cache.nix` (`name`, `publicKey`), written by hand. While `name` is empty nothing changes.
3. The cache is an extra source, never a requirement: `nix.settings.substituters` is added to the default one, and an unreachable or empty
   cache means a local build.
4. The signing key stays in Cachix; the repository holds only the public key.

## Consequences

- Faster rebuilds only when the host asks for the same store path that CI built. CI is pinned to the nixpkgs revision the servers run (`nixos-version --revision`, set in
  `config/nixpkgs-pin.toml`; a weekly workflow proposes the bump, see docs/dev-environment.md "The nixpkgs pin"); a host on another revision gets cache misses. The web frontend (`pkgs/hs-web.nix`) is built
  and pushed next to the Rust program. Not measured yet: compare the derivation hash on CI and on a server after the first push.
- A new trusted key means a compromised Cachix cache could serve a malicious binary to every host. The key is tied to the owner's account:
  protect it with two-factor login and rotate it by changing `publicKey` in a release.
- Cost: the free tier is limited; old paths can be removed in Cachix.

## Open points

- Rebuild time before and after (acceptance criterion of #253) needs a real server.
- Which paths to push besides the Rust program (the whole system closure is large).
