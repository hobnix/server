# Security policy

This repository is the core of a server that runs as root, holds the encryption keys of its disks and installs packages from other
repositories. Please report a vulnerability, a way to run code without a signed release, a way to reach an admin page from the internet,
or a leak of a secret **privately**: open a report under the Security tab of https://github.com/hobnix/server ("Report a vulnerability").
Do not open a public issue for it.

A fix is released through the normal update path (`hs update`); the advisory names the affected versions. The packages have their own policy
(https://github.com/hobnix/recipes and https://github.com/hobnix/extensions, `SECURITY.md`). How releases of packages are signed and how a
signing key is replaced: `config/trusted-keys/README.md`.
