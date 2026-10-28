# Trusted release keys

One file per default repository: `<repository name>.allowed_signers`, in the format of `ssh-keygen -Y verify` (`principal namespaces="git"
ssh-ed25519 AAAA...`). `hs pkg` installs only from release tags (`v1.2.3`) whose SSH signature verifies against these keys. A repository
without its file here is not used. Rotating a key = a commit here (the core is reviewed like everything else). Keys of repositories a
person adds with `hs pkg repo add` live on that server only (`/var/lib/hs/packages/keys/`).

Make a release: `git tag -s v1.2.0 -m "recipes 1.2.0"` with `gpg.format = ssh` and `user.signingkey` set.
