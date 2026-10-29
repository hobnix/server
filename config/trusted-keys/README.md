# Trusted release keys

One file per default repository: `<repository name>.allowed_signers`, in the format of `ssh-keygen -Y verify` (`principal namespaces="git"
ssh-ed25519 AAAA...`). `hs pkg` installs only from release tags (`v1.2.3`) whose SSH signature verifies against these keys. A repository
without its file here is not used. Rotating a key = a commit here (the core is reviewed like everything else). Keys of repositories a
person adds with `hs pkg repo add` live on that server only (`/var/lib/hs/packages/keys/`).

Make a release: `git tag -s v1.2.0 -m "recipes 1.2.0"` with `gpg.format = ssh` and `user.signingkey` set.

## Who may sign, and how a key is replaced

- **Who signs.** Releases of `hobnix/recipes` and `hobnix/extensions` are signed by the maintainer with the release key (an ed25519 key kept
  apart from the keys used to log in anywhere). Its public part is in `recipes.allowed_signers` and `extensions.allowed_signers` here. Each file
  holds one line per key that may sign: `principal namespaces="git" ssh-ed25519 AAAA...`.
- **How a release is made.** In the checkout of the package repository, on `main`: `bash <core>/scripts/dev/release.sh [patch|minor|major]`.
  It signs the next `vX.Y.Z`, checks the signature against the file here and pushes the tag. A server installs only a tag that verifies
  against the file in its own `/etc/nixos`, so a stolen GitHub account alone cannot get code onto a server.
- **Replacing a key** (planned, or after a loss). The order matters, because a server learns about a key only through `hs update` of the core:
  1. Add the new public key as an extra line in the `.allowed_signers` file(s) here, keep the old one, merge, and let the servers run `hs update`.
  2. Only then sign new package tags with the new key.
  3. Later, remove the old line in another commit (servers that never updated in between can no longer fetch until they do).
  A key that may have leaked is removed in the same commit that adds its successor; packages are re-released with the new key afterwards.
- **Keys you add yourself.** `hs pkg repo add <name> <url> --key <file>` keeps the key of that repository on that server only
  (`/var/lib/hs/packages/keys/`); it never changes this folder.
