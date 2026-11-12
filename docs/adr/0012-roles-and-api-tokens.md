# 0012: Roles and API tokens: viewer, app manager, admin

Status: Accepted (2026-11-10)
Issue: hobnix/server#257 (part of #195). The owner decides; nothing here is built.

## Context

- The web interface has one level of access. `scripts/web-serve.py` signs in members of the AD group Domain Admins (checked with winbind after
  `ntlm_auth` accepted the password) and one local account (default `adminuser`, checked with `unix_chkpwd`). The local account is the only way
  in while the storage is locked and the domain controller is down (docs/PLAN-web-backend.md). Anybody who is signed in may run every call in
  the allowlists `READS` and `CHANGES`.
- A session is a random token in a `HttpOnly; SameSite=Strict` cookie (8 h idle, 12 h at most), stored as a sha256 hash in
  `/run/hs-web/sessions.json`. There are no tokens for programs. Nothing outside a browser can call the API except through SSH and `sudo hs`.
- ADR 0006: the `hs sys` contract is the API and the web server is its only HTTP front. About 235 `sys` rows exist in
  `scripts/lib/registry.tsv`. The shape of each is in `docs/api/sys.toml` (13 hand-written entries today; rows without one are marked
  `x-hs-described: false` in `docs/api/openapi.json`). A change is always `plan`, then `start`; a destructive one needs `--confirm <name>`.
- The commands themselves know no users. They run as root (`hs-web.service`) and trust the caller. Where the check must live is therefore the
  web server, in front of the command (ADR 0006 rules 1 and 2).
- Audit exists (#167, closed): `scripts/lib/audit.sh` writes one line per changing command with an actor. It takes `HS_ACTOR` first and says in a
  comment that the web interface sets it to the signed-in user. A search of the repository finds no place that sets `HS_ACTOR`; so a web change is
  logged as the actor `web`, not as a person. That has to be verified and, if true, fixed before roles mean anything.
- People already exist as Samba/AD users and groups (`hs users ...`, docs/users-and-shares.md). A second program for self-service password
  changes is a package of its own (docs/PLAN-selfservice.md) and is not a role.
- Packages declare web pages, reads and changes in their manifest (`[web.reads]`, `[web.changes]`, docs/PLAN-extensions.md); #239 asks that
  their declared permissions are enforced. That is a rule about a package, this record is about a person. Both end up as a check at the same
  place.
- Nodes (TODO.md section D) read each other only through a forced SSH command with fixed words. That is a node-to-node trust, not a user role,
  and stays out of this record.

## Options

### Where the role of a person comes from

| | A. Local accounts and tokens only | B. Roles are AD groups | C. AD groups for people, tokens owned by a person (recommended) |
| --- | --- | --- | --- |
| Identity | a table of web users on the server | the Samba/AD user | the Samba/AD user |
| Role stored in | the same table | membership of three groups, for example `hs-viewers`, `hs-app-managers`, Domain Admins | the same groups |
| Change a role | `hs` command | `hs users` group membership, the tool people already use | same as B |
| Works while the DC is down | yes | no, except for the local account | local account (admin) only; tokens keep working, see decision 6 |
| A second user database | yes, to keep in line with Samba | no | no |
| Leaves a person | delete in two places | disable in one | disable in one; their tokens stop working |

A is the simplest to build and the worst to live with: it creates a second user list that drifts from Samba. B is clean but has no answer for a
program (a dashboard, a script, a mobile app) that cannot type a password. C is B plus tokens that belong to a person and never exceed that
person's role.

### Token format

| | opaque random string, stored hashed | signed token (JWT, macaroon) |
| --- | --- | --- |
| Check | a lookup on the server | signature, no lookup |
| Revoke | delete the row, at once | needs a deny list or a short life |
| Reuses | the pattern sessions already use (random, only the hash stored) | a signing key to guard and rotate |
| Fits | one server, one verifier | many independent verifiers |

There is one verifier (the web server on the node). Signed tokens solve a problem this design does not have.

### Where the check happens

1. **In the web server only (recommended).** The role is checked for each allowlist entry before the command runs. Roles are not part of the
   command: a person with a shell on the host is root through `sudo` and has no role to check.
2. In every command (the command reads the actor and decides). Rejected: about 235 places, written in bash, each a chance to forget.
3. In a proxy in front of the web server. Rejected for now: a second program that must know the allowlist.

## Decision (proposed)

1. **Three roles, ordered.** `viewer` < `app-manager` < `admin`; each includes the one before.
   - `viewer`: every read that does not show a secret. No `plan` or `start`.
   - `app-manager`: `plan` and `start` for instances and apps only: the groups `ct`, `docker`, `docker-app`, `recipes` and the app part of
     `pkg` (install, update, remove of recipes). Never storage, users, network, secrets, nodes, extensions' system parts.
   - `admin`: everything, as today. Members of Domain Admins and the local account.
2. **Every `sys` row has a required role, and a missing one means `admin`.** The role is a field in `docs/api/sys.toml` (or a file next to it
   that `scripts/openapi-gen.py` reads and copies into `docs/api/openapi.json` as `x-hs-role`). A test fails when a row in `registry.tsv` has
   no role field and is not on the explicit admin list, and when a row that runs a change (`plan`, `start`) is marked `viewer`. A new row cannot
   ship without a decision. Reads that expose a secret or a key are `admin` even though they change nothing: `vault`, `secrets`, `unlock`,
   `ssh-key list`, `node keyline`, `users details`. Initial assignment by group (of 238 rows in the file: 116 `viewer`, 14 `app-manager`, 108 `admin`) (the full list of all rows is in `docs/adr/0012-roles-sys-rows.tsv`, generated from this rule and from the verbs below; the owner reviews it with the record):

   | Group of rows | Read | Change |
   | --- | --- | --- |
   | state, health, jobs, event, disk, pool, shares, backup, deck, status, monitor, fm (browse) | viewer | admin |
   | ct, docker, docker-app, recipes, pkg (recipes) | viewer | app-manager |
   | users, vault, secrets, unlock, ssh-key, admin, config, system, release, net, dc, edge, gateway, vps, node, peers, remote, power | admin | admin |

   Two rows of the same group may differ (`sys jobs stop <unit>` stops a job of any kind: `admin`); the table is a default, the field per row wins.
3. **The check is one function in `scripts/web-serve.py`** that runs after the session or token is known and before the allowlist entry is run.
   A refused call is a 403 with the required role in the body; it runs nothing and is not an audit line. The page asks `GET /api/session` for the
   role and hides what the person cannot use; the 403 is the guard, the hiding is only help.
4. **API tokens belong to a person and carry a role.** Format `hst_` + 32 random bytes in base64url, shown once, stored as sha256 hash with an
   id, the owner, the role, a label, the creation time and the expiry. The role of a token is at most the role its owner has now: a lowered role
   lowers the token, a disabled account kills it. Sent as `Authorization: Bearer`. A token never needs a CSRF header and never gets a cookie.
   Default lifetime 90 days, at most 1 year, no token without an expiry. A token cannot create tokens, change roles or use `users`, `secrets`
   or `unlock`, whatever its role. Tokens are listed and revoked by their owner and by an admin.
5. **Tokens live on the system disk** (a file in `/var/lib/hs`, mode 0600, hashes only), not in the vault: a token must work after a boot
   before anyone unlocks. A stolen token gives what its role gives, so the three roles are the damage limit.
6. **Roles come from AD groups when the domain controller answers.** The result is cached for the life of the session (so a short DC outage does
   not sign everybody out) and read again at the next sign-in. A token takes its owner's role from the same cache, read again when the cache entry is older than one hour, so a lowered role or a disabled account reaches the token within the hour (not at once; decision 4 states the goal, this is the bound); when the DC has been
   unreachable for more than a day, tokens above `viewer` are refused until it answers. The local account is `admin` and stays the way in when
   the DC is down.
7. **No second user list.** The web server stores no password and no profile. People are Samba/AD users; the three groups are created by
   `hs users` (a follow-up). Linked to Samba means: same name, same password, same group membership; separate means: not at all. This record
   chooses linked.
8. **The audit line names the person.** The web server sets `HS_ACTOR` to the signed-in user, and to `<user> via token <id>` for a token (the
   id, never the token). `audit_actor` keeps its rule that the actor is made safe. A test starts a change through the web server with a
   user and finds that user in `hs sys audit`. Refused calls (decision 3) are counted in the web log, not in the audit.
9. **Extensions.** A package declares the least role for each of its reads and changes in its manifest; the effective rule is the higher of the
   package's and the row's. This is the place #239 enforces its permissions.

## Consequences

- A household member can look and a helper can restart an app without receiving the keys to the server.
- One more required field per row: about 235 decisions once, a test afterwards. The default of `admin` makes a forgotten row safe.
- Tokens add a table to guard and a command group to build (`hs token ...`, with `sys` rows and a web page). The web server gets a
  second way to sign in, so its tests (tests/web-login-test.py) grow.
- Roles are enforced only in the web server. Anyone with `sudo` on the host is unlimited; this record does not change that, and `hs` on the
  command line has no roles.
- A person who is `app-manager` can start code of an app they installed. They are trusted with the apps, not with the host; a recipe that mounts
  a share or opens a port is still a change an admin has to accept, and a rule for that is not written here.

## Decided by the owner (2026-11-10)

- **Logs are not for `viewer`.** `logs units` and `logs show` are `admin`; `ct logs` and `docker logs` are `app-manager` (the app's own page).
  Logs can hold secrets. The rows in `0012-roles-sys-rows.tsv` follow.
- **The audit log is `admin` only** (it names people).
- **`app-manager` sees an app's logs, never the console of an instance.**
- **Three global roles first;** no per-object scope (this app, this share).
- **Still open, as follow-up issues once accepted:** the names of the AD groups and how `hs users` creates them without surprising an
  existing domain; a rate limit and lockout for token use (AD lockout does not apply to a token); the role field and its test, the check in
  `web-serve.py`, `HS_ACTOR` from the web server, `hs token` (create, list, revoke) with its `sys` rows, the role-aware web interface, extension manifests.
