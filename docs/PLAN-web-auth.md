# Plan: web sign-in hardening (lockout, session control, roles)

Status: options for the owner; nothing is built. Issues: hobnix/server#502 (login lockout), hobnix/server#504 (roles, session list, sign out
everywhere). Found in the security review #433 (docs/THREAT-MODEL-web.md, "Known gaps"). Milestone 0.2. Not tested on hardware yet.

## Goal
Decide what ships in 0.2 and what waits. The role model itself is already decided: ADR 0012 (viewer, app-manager, admin; checked in the web
server; build tracked by #434 in 0.8). This plan does not reopen it; it only says how much of #504 can and should land before 0.8.

## What is true today (scripts/web-serve.py)
- `Throttle` (class near line 644): 5 failures in 10 min lock a key for 30 s, doubling to 15 min. Login uses two keys: the client address
  and the user name (`app.throttle.wait/failed(*keys)`, around lines 2885-2972; unlock and setup use the same class). The right password also waits.
- `Sessions`: 256-bit cookie token, only its sha256 stored in `/run/hs-web/sessions.json` (0600); user, realm, times, ip. 8 h idle, 12 h at most. `drop(token)` ends one session (logout). A domain session ends when the storage locks.
- Throttle state is in memory only: `systemctl restart hs-web` clears it (sessions survive through the file). That is today's break-glass.
- The web interface never changes a password except first setup (`chpasswd`). The local `adminuser` password changes in a shell (`passwd`), a domain password in AD.

## #502: the only admin can be locked out from the LAN

Anyone who can reach the port can send 5 wrong passwords for `adminuser` from their own address. The user-name key then locks the real admin
for 30 s, doubling to 15 min, and the attacker repeats it. The address key is fine; the user-name key is the problem. (The `X-Forwarded-For`
issue #503 is separate: it decides whether the address key can be faked. This plan assumes it is fixed there.)

| | A. Address key only | B. Exempt known addresses | C. Address key locks, user key only slows (recommended) | D. Keep, add a reset command |
| --- | --- | --- | --- | --- |
| Admin locked out by a stranger | no | no, from listed addresses; yes from others | no: a correct password is never refused because of the user key | yes, until reset |
| Guessing one account from many addresses | not limited (needs many addresses on a LAN; faked addresses are #503) | not limited for listed addresses | limited: while the user key has failures, every wrong guess waits longer (up to a few seconds), so the rate stays low | limited (the lock) |
| New state to keep | none | a list of addresses to configure and keep right | none | a command and a doc |
| Failure mode | a distributed guess goes unslowed | a spoofed or shared address (NAT, tailscale serve) defeats it | slow wrong guesses hold a request thread each (bounded by the server's thread limit and the 4096-key cap) | the lockout stays an attack that works |

- **A** is the smallest change but drops all account-level protection; a weak local password would then be guessed at the address-lock rate per address.
- **B** needs configuration most households will not do, and "known good" is hard to state behind a proxy.
- **C** keeps account-level pressure (the delay) without ever refusing the real owner. Implementation: in the login handler the user key no longer feeds `wait()` (the 429 answer); it only raises the delay applied to a wrong password (`fail_delay` times a factor from the user key's recent failures, capped, for example 4 s). The address key stays exactly as today. Tests: a stranger's 20 wrong tries do not block a right password from another address; the capped delay; ThrottleBounds still holds.
- **D** is not a fix. It stays useful as a break-glass: an `hs` command that clears the throttle (`hs web unlock-login`, a thin wrapper that restarts hs-web or asks it to clear the table). Optional; `systemctl restart hs-web` over SSH works today.

**Recommendation:** C in 0.2, with the existing restart written into docs/web.md as the reset. No new command unless the owner wants one (question 2).
Domain accounts: the web throttle never locked the AD account itself, but AD's own lockout still applies to wrong passwords sent to the
domain controller; C does not change that. Size: small (one handler change, about 4 tests).

## #504: roles, session list, sign out everywhere

Three separate wishes. They differ a lot in size, so they should not travel together.

| Part | What | Size | Depends on roles? |
| --- | --- | --- | --- |
| 1. Password change ends sessions | a session records a fingerprint of the account's credential; a mismatch ends it | small | no |
| 2. Session list | `GET /api/sessions`: id, user, realm, signed in, last seen, address, short browser name; the current one marked; shown on a settings page | medium | no (the shape grows with roles) |
| 3. Sign out everywhere / end one | `POST /api/sessions/end` (one id) and `/end-others`; CSRF gate as for every POST; one audit line each | small once 2 exists | no |
| 4. Read-only and app-manager roles | ADR 0012: required role per `sys` row, the check in web-serve.py, `HS_ACTOR`, tokens | large (about 235 rows decided once, a test, a page) | it is the roles |

### Part 1: how a password change ends sessions
- **Local account (`adminuser`):** the session stores a hash of the `/etc/shadow` password field for that user (hs-web runs as root and can read it; only a hash of the field is kept, in the 0600 session file). At each `Sessions.get` the current fingerprint is compared (the shadow read is cached for 30 s); a mismatch drops the session.
- **Domain account:** there is no cheap, reliable "password changed" signal from the web server. Options: ignore (sessions end by the 12 h limit or by "sign out everywhere"), or re-check through winbind every hour. Recommendation: ignore for 0.2 and say so in the threat model; an admin can end sessions by hand through part 3.
- Setup and first login are unaffected (a fresh token is made).

### Parts 2 and 3: scope of the list
- Every account is admin today, so every admin may see and end every session (one list). That is safe now and wrong after roles. Recommendation: build "all sessions" now and let #434 narrow it to "own sessions" for non-admins in the same function.
- The id shown and sent is a short prefix of the stored sha256, never the cookie token. Ending the current session is allowed (same as logout).
- The session file gets two optional fields (`seen`, `ua`; `ip` exists); old files load without them.

### Part 4: roles in 0.2 or 0.8?
| | X. Keep ADR 0012's plan: roles are #434 in 0.8 (recommended) | Y. Pull roles into 0.2 | Z. A coarse interim in 0.2 (a "read-only" flag per local account) |
| --- | --- | --- | --- |
| Ships | parts 1-3 in 0.2; roles with tokens and the page in 0.8 | all of it in 0.2 | a flag that blocks all of `CHANGES`, terminal and unlock |
| Risk to the 0.2 date | low | high: classifying the 235 rows, the admin-default test, the role-aware page, `HS_ACTOR` | medium |
| Throw-away work | none | none | yes: it conflicts with the AD-group design of ADR 0012 (roles come from groups), and a local-only flag has no home for domain people |
| Leaves open in 0.2 | every account is still root-equivalent (stated in the threat model) | nothing | local accounts only |

Recommendation: X. Parts 1-3 reduce the damage of a stolen session or a leaked password now; roles reduce the damage of a legitimate but
less trusted person, which belongs with tokens and extension permissions in 0.8. #504 is closed when parts 1-3 land; #434 stays open for part 4.

## What ships when
| Release | Content |
| --- | --- |
| 0.2 | #502 option C (and the docs/web.md reset note); #504 parts 1, 2, 3; threat-model rows updated ("Known gaps" shrink); changelog entry; tests in tests/web-login-test.py |
| 0.8 | #434: roles, tokens, `HS_ACTOR`, role-aware page (ADR 0012); the session list narrows to own sessions for non-admins; two-factor/SSO (#462) |
| later | a "password changed" signal for domain accounts; a notice on the sign-in page after many failed tries |

## Open questions for the owner
1. #502: accept option C (the user key only slows, never refuses the right password), or prefer A (address key only, simplest)?
2. #502: a break-glass command (`hs web unlock-login`) in 0.2, or is the documented `systemctl restart hs-web` enough?
3. #504: keep roles in 0.8 (#434) as ADR 0012 says, ship only parts 1-3 in 0.2, then close #504?
4. #504: should the session list show all sessions (everyone is admin today) or only the signed-in user's own?
5. #504: accept that a changed domain password does not end web sessions in 0.2 (documented), only "sign out everywhere"?
