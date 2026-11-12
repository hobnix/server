# 0022: First-run web setup with a one-time console token

Status: Accepted (2026-11-10), with the plain-HTTP limit under Open points.
Issue: hobnix/server#183 (part of #173, Installation and Onboarding). The owner decides.

Numbers 0018 to 0021 are taken by other records (interactive recipe runs and the open #260, #268, #261); this one depends on none of them.

## Context (checked 2026-11-08 on develop)

- A new server is installed from the ISO (`installer/iso.nix`, `scripts/install-wizard.sh`). After the first boot there is no web login that works:
  `scripts/web-serve.py` signs in members of Domain Admins and one local account (`adminuser`, checked with `unix_chkpwd`, `nonull`), and the
  local account has no password until a person sets one on the console. The first steps today are `hs first-run` (a checklist, `setupDone`) and
  the console.
- The web interface is plain HTTP on the LAN and Tailscale, never public (`.claude/rules/web.md`). Failed logins are throttled per client address
  and per user name (`Throttle`); a session is a random cookie token stored as a hash.
- `POST /api/unlock` is the one POST that changes the system before anybody is signed in as an account that exists on the machine; it is in-process,
  throttled, and the secret goes to a helper on stdin only. The setup follows that pattern.
- Anybody on the same network can open the port as soon as `webUi` is on. Before setup the page must prove that its user has physical (or
  console) access to the machine, and it must do that without sending anything secret over the network that the person did not type.

## Decision

1. **The flag.** One file, `$HS_STATE_DIR/first-run.json` (mode 0600, replaced atomically; `scripts/first_run.py`), says `pending` or `done`.
   **No file means "not a first-run server"**: an upgraded or already configured server never shows a setup. Only the console command creates
   the file (rule 3); the web interface never does.
2. **The token** is 20 characters from a 32-letter alphabet without `0 O 1 I` (100 bits), shown as `XXXXX-XXXXX-XXXXX-XXXXX`, made with
   `secrets`. Input is case- and dash-insensitive. The file keeps only `sha256("hs-first-run:" + token)`, never the token.
3. **Printed on the console only.** `hs setup-code issue` (root) prints the token between two marker lines on its standard output, so a boot
   unit with `StandardOutput=tty` and `TTYPath=/dev/console` shows it on the screen and on the serial port. It is never written to a file, the
   journal, the event log, an e-mail, a notification, the web, or `/etc/issue`. Neither the web server nor any `hs sys` read can return it.
4. **Single use.** The token is checked, the local admin's password is set and the flag turns to `done` while one lock is held; the
   token is consumed only when the password was set. A second request with the same token gets 409. A failed password helper keeps the token
   usable (the person retries); a weak password (under 10 characters) is refused before the token is touched.
5. **Expiry.** A token lives 60 minutes from `issue`. An expired token answers 403 and the page tells the person to run `hs setup-code issue`.
6. **Rate limit, two layers.** (a) The existing `Throttle`, per client address and one global key: five failures in ten minutes lock for
   30 s, doubling to 15 minutes. (b) A **burn counter** stored with the token: five wrong tokens in total, from anybody, kill that token
   for good (403 "used up"); only the console can make a new one. Online guessing of 100 bits is hopeless anyway; the burn counter exists to
   make a noisy attack stop and to be visible (`hs setup-code status`).
7. **Binding to the first admin.** The account is the machine's local admin (`localUser`, default `adminuser`), the one account that works
   while storage is locked. Redeeming the token sets its password (`chpasswd`, the line `user:password` on stdin, never an argument), records the
   name in the flag (`done`, `user`) and signs the person in with a normal `local` session. The setup creates no other account and no domain
   admin; domain admins come later through the checklist.
8. **LAN only.** `POST /api/setup` answers only to private addresses (`private_client`: RFC 1918, Tailscale CGNAT, loopback, ULA); a request
   from a public address gets 403 and the token is not touched. `GET /api/hello` says only `setup: {open: true|false}`: not the expiry, not the
   failure count.
9. **After a reboot** a `pending` flag survives (the file is in the state folder) but the old token's remaining time keeps running. The boot
   unit runs `hs setup-code issue` again **only while the flag is `pending`**, which replaces the old token: the screen always shows the
   token that works. Once `done`, `issue` refuses (exit 1) and prints nothing.
10. **If the token leaks.** Before it is used: run `hs setup-code issue` on the console (the old token is dead at once) or wait for expiry.
    After somebody used it: the setup is `done` and that person has the admin password; the owner, who has the console, sets a new password
    (`passwd adminuser`) and, if the server was exposed, checks `hs sys audit` and sessions (`/run/hs-web/sessions.json` is cleared by restarting
    hs-web). `hs setup-code reset` starts a setup again and is root-only on the console. No remote recovery path exists on purpose.
11. **Logging.** The journal gets one line per refusal (`web setup refused: wrong code from <ip>`) and one for success; never the token or the
    password. A test checks that.

## Threat model

| Threat | Answer |
| --- | --- |
| A neighbour on the LAN opens the page before the owner | Cannot go further without the console code (rule 3). The page is visible, so the person sees that a setup is open; it exposes only that. |
| Guessing the token | 100 bits, 5 wrong tries burn it, per-address throttle. |
| Reading the token from the network | It never travels from the server; the person types it. The code and the new password do cross the LAN once in plain HTTP when submitted (same as today's sign-in): a person on the same segment who can sniff can take the setup. Residual risk, stated in the guide; TLS belongs to a separate decision. |
| Reading the token from disk or logs | Only a salted-by-prefix hash is stored; the console banner is not logged (unit output goes to the tty). |
| Replaying a used token | Flag is `done`; 409. |
| Racing two requests | One lock covers check, password change and consume. |
| Setup shown on an existing server after an update | No flag file, no setup (rule 1). |
| Someone on the console | They already own the machine (root login, bootloader). Out of scope. |
| Public address reaching the port | 403 (rule 8); the port is not meant to be forwarded (`web.md`). |
| Session theft after setup | Same cookie rules as sign-in (`HttpOnly`, `SameSite=Strict`, Origin check). |

## Consequences

- The ISO path gets a boot step that runs `hs setup-code issue` while `pending` and a step that creates the flag when the installer finishes.
  Neither is built here: this record covers the server part (token, flag, endpoint, sign-in page).
- `setupDone` and `hs first-run` stay; the web wizard replaces only "set the admin password on the console".
- Passwords for domain accounts are unaffected.

## Open points

- The boot unit and the installer hook (create the flag, show the banner on tty1 and ttyS0). Not tested on hardware or in a real install.
- Whether the setup should offer more steps after the password (language, server name, a notification address) as a wizard; the sign-in page only
  does the first step now.
- TLS or a self-signed certificate for the setup page. **Accepted limit (2026-11-10, owner):** the setup page is plain HTTP on the LAN until TLS is decided; the code and the new password cross the LAN once. The guide says so.
- Whether `hs setup-code reset` should also be offered from the web while signed in (it is not).
