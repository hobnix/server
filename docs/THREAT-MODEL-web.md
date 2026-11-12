# Threat model: the web service

Review of the web service (`scripts/web-serve.py`, unit `hs-web`) for milestone 0.2, issue 433. It says who can reach the service, what each
sign-in can start, what is protected against what, and what is known to be open. Status: reviewed by reading the code and the tests; **no
penetration test and no run on real hardware** ("Not tested on hardware yet.").

## What the service is
One Python process on the host, as root, plain HTTP on the home network (`webLan`) and Tailscale (HTTPS ends in `tailscale serve`). It
serves the Svelte frontend and wraps `hs sys ...` (reads) and `plan`/`start` (changes). It is never in Incus and never behind a Zoraxy rule.

## Who can reach it
| Who | Reaches | Can do |
| --- | --- | --- |
| Anyone on the home network or Tailscale (no login) | `/api/hello`, the sign-in page, static files, `/theme.css`, `/api/login`, `/api/setup` (home addresses only) | read three status lines (backup age, instance count, disk warnings); try passwords (throttled) |
| The internet | nothing: no router rule, no Zoraxy rule (`ADMIN_TARGETS` guard) | nothing |
| A signed-in Domain Admin | every read, every change in the `CHANGES` allowlist, unlock, the browser terminal if `webTerminal` is on | **root-equivalent**: the terminal is a shell as adminuser with sudo, and changes start root commands |
| The local `adminuser` | the same; the only way in while the storage is locked | the same |
| A browser of a signed-in admin, driven by another web page | only what SameSite and the Origin check let through (below) | nothing, if those hold |
| A process or user on the server itself | the loopback port, as any other client; `X-Forwarded-For` (last entry) is trusted from loopback only with `HS_WEB_TRUST_PROXY` | sign-in attempts; no session without a password |

There is one role: admin. There is no read-only role; "viewer" does not exist, so every account that can sign in is root-equivalent.
Trust therefore sits in the Domain Admins group and in the local admin password.

## Assets
Root on the host; the disk encryption passphrase (typed to unlock, passed on stdin, never logged); the secrets under the vault; the
data of every share and instance.

## Protections and where they are
| Threat | Protection | Where | Test |
| --- | --- | --- | --- |
| Password guessing | 5 failures in 10 min lock the client address and the user name for 30 s, doubling to 15 min; the right password also waits; every failure waits `HS_WEB_FAIL_DELAY`; the same throttle covers unlock and first setup; the table is capped at 4096 keys | `Throttle` | `web-login-test.py` Login, ThrottleBounds |
| Cross-site request forgery | Cookie `HttpOnly; SameSite=Strict` (`Secure` behind tailscale serve); every POST needs `Content-Type: application/json`, an `Origin` equal to `Host`, and, except login, setup and logout, a session and the `X-CSRF-Token` of that session. One gate in `do_POST` runs before any handler, so a new handler cannot forget it. The test lists every POST path and fails when one is not covered. | `do_POST` | `CsrfGate` |
| Cross-site WebSocket hijack (terminal, VM console) | `Origin` must equal `Host`; the upgrade also needs a one-time ticket from a CSRF-checked POST, bound to the session | `_terminal_ws`, `_vmconsole_ws` | `web-terminal-test.py`, `web-vmconsole-test.py` |
| Session theft by script | token is random (256 bit), `HttpOnly`; only a SHA-256 of it is written to disk (`/run/hs-web`, 0600); CSP, `nosniff`, `no-referrer`, `no-store` | `Sessions`, `_headers` | `SessionFile`, `Pages` |
| Session fixation | a login or setup discards the cookie that came with it and makes a new token | `_login`, `_setup` | `test_a_login_replaces_the_cookie_it_came_with` |
| Stale sessions | idle 8 h, absolute 12 h; a domain session ends when the storage locks | `Sessions.get` | `Login` |
| Command injection through a change | closed allowlist (`CHANGES`), every word a full-match regex, no shell, secrets on stdin only, `--by`/`--role` added by the server | `validate_change` | `Changes` |
| A read that changes something | `READS` allowlist, each entry must be a `sys` row of kind read | `READS` | `test_every_entry_is_a_registry_row_and_none_changes_anything` |
| Admin page made public | `ADMIN_TARGETS` guard in `services.py` | services | `services.sh` |

## Review of the `hs sys` allowlists
Method: the matching rules of `READS` and `CHANGES` were checked as a whole, not value by value. Checked: every word is matched with
`fullmatch` (a trailing newline cannot slip through); the names and ids sampled start with a letter or digit; free-text option values
(`FM_PATH`, `--title`, `--description`) may start with `-` but always follow their option as a separate word; paths cannot contain `..` (`CT_PATH`, `SHARE_PATH`, `DISKPATH`) or are checked again by the script (file manager);
passphrases, passwords and the SSH/package keys use stdin; `--request-header` and similar fields are one printable line. Not done: a
row-by-row review of every script behind every row (several hundred). What the review found is under "Findings".

## Findings
Fixed in this change:
1. **CSRF check was per handler.** Every handler did it by hand; a new one could forget. Now one gate in `do_POST`, with a test that reads the path list.
2. **Unlock throttle used the proxy's address.** Behind `tailscale serve` all clients shared one key. It uses the forwarded client like login.
3. **Throttle table unbounded.** A client could fill memory with made-up user names. Capped at 4096 keys.
4. **Session fixation hygiene.** A login now ends the cookie it arrived with.

5. **DNS rebinding (#501).** Every request (GET, HEAD, POST, before any handler) needs a `Host` that names this server: an IP literal, the host name, `<host>.local`, a name below the gateway's local domain, or `<host>.<tailnet>.ts.net` (any `*.ts.net` name behind `tailscale serve`, where the machine name there can differ). Anything else gets 421. A correct setup is not locked out: the list is built from what the server knows, and the escape is the runtime setting `webAllowedHosts` (`hs config set webAllowedHosts nas.example.org,files.lan`, no rebuild; `*` switches the check off; the refusal is logged with the name and the answer names the setting). Test: `HostAllowlist` in `web-login-test.py`.
6. **`X-Forwarded-For` (#503).** From loopback the LAST entry is the client: the one our own proxy added. `tailscale serve` and Traefik (entry points without trusted forwarders) set the header from the peer they saw; a proxy that appends keeps the client's own text in front, so the first entry is spoofable. Not run on hardware yet: check what `tailscale serve` sends. A local process can still write any header; it is a client like any other (see above).

Open (filed as issues in milestone 0.2, see the pull request):
- Per-user lockout lets a LAN client keep the one admin account locked out (denial of service).
- One role only: no read-only account, and the browser terminal is root-equivalent by design.
- No `__Host-` cookie prefix and no `Secure` flag on plain HTTP (by design on the home network; HTTP sends the cookie in clear).
- Session list and a "sign out everywhere" button do not exist; sessions of the same admin are never ended by a password change.
- Row-by-row review of the scripts behind the allowlists, and free-text answers (`recipes --set`, `routes --request-header`).
