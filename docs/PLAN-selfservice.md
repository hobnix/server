# Plan: self-service password change for domain users

Status: built (spec .work/ad-selfservice/spec.md), tests pass in WSL, not run on real hardware. Decided with the maintainer; open points are at the end.

## Goal
A person with a domain account (Samba AD, capability `ad`) can change their own password from a web page, also when they are not on
the home network. Nothing else: user creation, groups, locking and resets stay admin-only (`hs user`).

## Decisions
- **Scope:** password only. Display name and email stay admin-only.
- **Package form:** an extension package `extensions/ad-selfservice/` in the hobnix/extensions repository (installed with `hs pkg install`)
  (`extension = true`, own `commands.tsv`), off by default, `hs ext enable ad-selfservice`. It requires the capabilities `ad` and `gateway`.
- **Exposure:** configurable, default private (only `privateInterfaces`). An admin opts in to a public route. Every route must be TLS: until the gateway has `lan-https`, private mode cannot start; public goes through traefik-public only.

## Architecture
- A small separate service on 127.0.0.1:8486 (a transient systemd unit on the host, started again at boot by the core's extension boot
  hook) behind the host Traefik. It is NOT the admin web interface: that one is never public.
- It changes the password with the **user's own credentials** (old password checked by the domain controller, `smbpasswd -r <DC> -s`
  (SAMR change over SMB3; the DC checks the old password)). It holds no admin credentials, so a compromise cannot reset other users.
- Passwords travel only over stdin, never argv or the environment. The service has no stored secret: the CSRF key is random per process, in memory only.
- Public mode: a service descriptor with `exposure = public-ok` and `public_paths` limited to the form and its API (the guard in
  scripts/services.py accepts nothing wider), only with `reverseProxy = traefik-public`. Private mode: the same descriptor with `private-ok`.

## Security requirements (v1)
- Rate limit per IP and per account with growing delay; document that AD lockout lets a stranger lock an account on a public form.
- Same message and timing for unknown user and wrong password.
- AD enforces the password policy; show its text without leaking account state.
- TLS from the proxy on every route (start refuses without one; the service refuses plain-HTTP requests), CSRF token, strict headers, no session or cookie beyond one request.
- Audit log (time, IP, user, result, never a password), readable through `hs`.
- Admin accounts (Administrator, krbtgt, Guest) are refused; Domain Admins use `hs user`.
- Optional: IP or country allowlist for the public route.

## Work items
1. Package skeleton: `capability.toml`, rows `start`, `stop`,
   `status`, `expose`, `log` and `sys ext ad-selfservice boot` in the package's own commands.tsv (no core registry.tsv rows).
2. Service (Python, stdlib), rate limiter and error mapping with unit tests (tests/ad-selfservice.sh in the extensions repository (`HS_CORE=<core> bash tests/run-all.sh ad-selfservice`)).
3. Service descriptor and the private/public switch (`hs ext ad-selfservice expose private|public`, shows a plan first).
4. Guide following docs/GUIDE-TEMPLATE.md ("Not tested on hardware yet."), changelog entry.
5. Review against the rules in capabilities/reverse-proxy/NOTES.md and capabilities/ad/NOTES.md.

## Decided points
- Own unit on the host plus the core boot hook (`hs-ext-boot`), no new container.
- Lockout = the AD policy plus the service's own counters (Q4 of the spec).
- Form language = the `language` setting.
