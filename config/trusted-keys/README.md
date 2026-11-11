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

## The core: `server.allowed_signers`

`hs update` on the `stable` and `beta` channels checks the signature of the release tag of the core itself (`git tag -v`) against
`server.allowed_signers` in this folder, in the same format as the other files. The file holds the release key (one line). A server whose checkout lacks the file or its key
refuses to move onto any tag, so servers need an `hs update` that brings the file before the first tag. Servers without a release tag, and the `edge` channel, do not use it.

## The keys of the release workflows: `release-ci`

A release can also be cut from GitHub (Actions, the workflow `release` of each repository), so that it does not need the maintainer's
machine. The workflow signs with a key of its own, never with the maintainer's key:

- **One key per repository**, principal `release-ci`, as one more line of that repository's file here (`server`, `recipes`, `extensions`,
  `capabilities`). The maintainer's line stays: a release from the maintainer's machine keeps working, and both are checked the same way.
- **Where the private key is.** Only in the secret `RELEASE_SIGNING_KEY` of the GitHub environment `release` of that repository. The
  environment has a required reviewer and allows the branch `main` only, so the job that signs waits for the maintainer's approval.
- **Making one** (the maintainer, once per repository; the key has no passphrase because the workflow cannot type one):
  ```bash
  ssh-keygen -t ed25519 -N '' -C hobnix-release-ci -f release-ci
  ```
  The line for the file here is `release-ci namespaces="git" ` followed by the first two fields of `release-ci.pub`. Put the content of
  `release-ci` into the secret, then delete both files.
- **What this changes.** With the maintainer's key alone, a stolen GitHub account cannot get code onto a server. With a `release-ci` line,
  somebody who can run the workflow **and** pass the approval of the environment can sign for that repository. The guards are the approval,
  the checks the workflow runs before it signs, and that the key is one line that can be removed without touching the maintainer's key.
- **Replacing it** follows the order above: add the new line, merge, let servers run `hs update`, change the secret, release, remove the old
  line later.
- **A leaked or lost key.** Remove its line by a pull request at once and delete the secret. A server that updated afterwards refuses every
  tag signed with it, also the ones already published: release again (the next number) with the maintainer's key or a new one. A pushed tag
  is never moved or deleted.

The lines are added before the first release, because a server learns a key only through `hs update` of the core. The `release-ci` lines are
not in the files yet, and no workflow has signed with such a key: **Not tested on hardware yet.**
