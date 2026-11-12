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
passphrases, passwords and the SSH/package keys use stdin; `--request-header` and similar fields are one printable line. The scripts behind the rows were reviewed afterwards, see the next section. What the first review found is under "Findings".

## Row-by-row review of the scripts behind the allowlists (#505)
Method: for every `CHANGES` area the script behind it (`hs sys <area> plan|start` in `scripts/lib/registry.tsv`) was read for how it takes
each option value: is the value checked again inside the script (so it does not depend on the web pattern), is it handed on as ONE argument
(never in a string that is parsed again), does a value that starts with `-` reach a command as an option (`--` or a fixed prefix), can a path
leave its folder (`..`, links), does the root script write the value into a file that is read again (TOML, conf, `.env`, LDIF). hs-web.service
and so every script below runs as root; none of them reads a value as shell code (`eval` / `bash -c` / `sh -c` are only used with constant
text and the values as positional parameters; the one `eval` in fm.sh expands fixed variable names).

What stays in the test suite: `WordsThatStartWithADash` in tests/web-changes-test.py (no positional word of a change and no read argument
accepts a leading dash; a value that follows its option as a separate word is the intended exception) and the per-script tests added with
each fix (tests/docker-registry.sh, iso.sh, manage-legacy.sh, web-data-settings.sh, dialogues.sh, fm.sh, notify-channel.sh).

Depth: **read** = the argument handling and every place the value is used was read. **outline** = the validation lines and the commands that
receive the values were read, not every line of the script. Verdict: **ok**, **fixed** (in this change), **note** (a remark).

| Row (`CHANGES` area: verbs) | Script | Depth | Verdict |
|---|---|---|---|
| `jobs`: run, stop, answer | jobs-change.sh, jobs-answer.sh | read | ok. The unit must match `hs-*.service`; `systemctl start/stop` get it last. The answer is one line on stdin. |
| `fm`: copy, move, delete, rename, mkdir | fm.sh | read | ok. `fm_clean_path` refuses `..`, empty parts and control characters; the real path (`readlink -f`) must stay below the location root; the selection comes on stdin, NUL separated, names hold no `/`. **fixed:** `--sel-file` (not in the web allowlist) accepted `<jobs>/../../x.sel` because `*` in a `case` pattern matches `/`. |
| `ssh-key`: add, remove | ssh-key-change.sh | read | ok. One line, no control characters, the key line is matched again in the script and `ssh-keygen -lf` must accept it. |
| `pool`: add, adopt, replace, remove, ... | pool-change.sh | outline | ok. Pool name `^[a-z][a-z0-9_-]*$`; disk ids have no `/` or `..`; the passphrase is stdin. |
| `incident` | storage-incident.sh | web pattern only | ok. Fixed verbs in the allowlist. |
| `disk`: format, mount, temp-mount, ... | disk-change.sh | outline | ok. Disk name starts with a letter or digit and holds no `..`; partitions `^[a-z0-9][a-z0-9-]*$`; mount names and share names re-checked. |
| `peers`: offer, add, remove, revoke, attach, detach | peer-change.sh | read | ok. Every value goes through `valid` (peer, host, share, login, domain, path); the password is stdin. note: `attach --path` is a path inside an instance and may hold `..` (the instance's own file system). |
| `secrets`: header-backup, move, close, fix | vault-change.sh (called by the Rust `secrets`) | read | ok. Secret names `^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$`; an option that starts with `-` is refused. |
| `testlab`: run | testlab-change.sh, testlab.sh | outline | ok. `--stage` is a fixed list; `--ref` is a dry run of testlab.sh, which refuses anything that is not a branch, tag or commit name (never an option or a refspec). |
| `admin`: fans-clean, ... | admin-change.sh | outline | ok. `--seconds` is a number 3 to 30. |
| `dc`: renew, ca | dc-change.sh | outline | ok. `--dc` is an instance name that starts with a letter or digit. |
| `net`: set router | net-change.sh | outline | ok. Address `^https?://[A-Za-z0-9._:-]+$`; the key is stdin. |
| `routes`: apply, adopt, import, remove, set, add, edit | services-change.sh, services.py | read | ok. Every value reaches services.py as one argument; the descriptor is written with `q()` (backslash and quote escaped, one line), so a title, header or description cannot add a key. `--request-header` / `--response-header` are `Name: value` on one printable line. note: services.py finds an option by its name in the argument list, so a title that is literally `--port` can confuse the parsing of the SAME call (it ends in an error or a wrong field of that service); it cannot reach another service. |
| `pkg`: install, update, remove, fetch, repo-add, repo-remove, check-draft | pkg-change.sh, pkg_repo.py | read | ok. The repository address must start `https://`, `ssh://git@` or `git@` and holds no `..`; only a tag whose signature verifies is used. **fixed:** `git clone` got no `--` before the address (defence in depth). |
| `recipes`: run | recipe-change.sh | read | ok. `--set KEY=value`: KEY is `[A-Z][A-Z0-9_]*` and must be a question of the recipe (or a `DASH_` / `PUBLIC_` / `PUBLIC_NAME_` key with its own pattern); the value must fit the recipe's pattern and holds no control character; it reaches the job as ONE `RECIPE_KEY=value` line of the job environment, never in argv. A secret goes into a root-only file. `--name` is a container name that starts with a letter or digit. |
| `vps`: update, watch | vps-change.sh | outline | ok. The host comes from machine.toml and is checked; the key is forced to two words. |
| `parts`: enable, disable | part-change.sh | web pattern only | ok. |
| `node`: add, remove, ... | node-change.sh | outline | ok. Name `^[a-z][a-z0-9-]*$`, host starts with a letter or digit and holds no `..`, port is a number. |
| `ct`: start, stop, snapshot, restore, add-storage, set, ip, create, delete, ... | ct-change.sh, manage-ct.sh | outline | ok. Names, labels and snapshot names are checked again (`^[A-Za-z0-9][A-Za-z0-9._-]*$`); binds match a pattern without `..`; the path inside the instance is one argument (`path=<value>`) of incus. |
| `backup`: now, restore, offsite-set, init, drill, ... | backup-change.sh | outline | ok. The restic repository may not start with `-` or hold `..`; disk ids and counts are checked. |
| `shares`: add, rename, snapshot, rollback, perm, restore, purge, ... | share-change.sh, share-snap.sh, share-restore.sh | read | ok. Share names, labels, snapshot ids, SIDs and `--as` are checked again. **fixed:** `restore <folder>` joined a folder with `..` to the share path (the web interface and share-change.sh refused it, share-restore.sh did not). |
| `users`: user-add, user-edit, group-*, password, membership, ... | user-change.sh, manage-users.sh | read | ok. A name must be in the real list (`grep -qixF`) before it reaches an LDAP filter; `samba-tool` gets each value as one argument; `--edit` writes LDIF with base64 values. **fixed:** `--add --full` was not checked in manage-users.sh (only the web interface and `--edit` had the pattern). |
| `expiry`: add, remove | expiry-change.sh, expiry.sh | read | ok. Name from a small character set; the hint holds no tab or newline; written with `printf '%s\t%s\t%s'`. |
| `iso`: add, remove | iso-change.sh | read | ok. URL pattern without user name; `curl --proto =http,https -- <url>`; a path holds no `..`; the name ends in `.iso`; the image must carry the ISO 9660 mark; a checksum is required unless `--no-checksum`. **fixed:** the check "this server does not download from itself" was bypassed by `2130706433`, `0x7f.1`, `0177.0.0.1` and `localhost.` (curl reads them as 127.0.0.1). A name that only resolves to a loopback or private address (DNS) is still accepted: a LAN mirror is a legitimate source. |
| `health`: ack, unack, resume | health-change.sh | web pattern only | ok. |
| `release`: set channel | release-change.sh | web pattern only | ok. |
| `system`: sync, scrub, update, rebuild, gc, rollback, reboot, shutdown | system-change.sh | outline | ok. Pool `^[a-z][a-z0-9_-]*$`, `--days` is a number. |
| `gateway`: set, ... | gateway-setup.sh | web pattern only | ok. `GW_SET` is a fixed key and `[A-Za-z0-9.,@_+-]` as the value. |
| `docker`: set, ... | docker-setup.sh | web pattern only | ok. `DOCKER_SET` lists the keys and their values. |
| `docker-app`: start, stop, app-save, app-write, rebuild, delete | docker-app-change.sh | outline | ok. App name `^[a-z0-9][a-z0-9_-]*$`; paths and the project name go to `incus exec ... -- sh -c '<constant>' sh "$arg"` as positional parameters, never into the script text; the document comes as bytes on stdin. |
| `docker-registry`: add, remove | docker-registry-change.sh, lib/docker-auth.sh | read | ok. Token on stdin, in a throwaway `DOCKER_CONFIG`. **fixed:** the address could be `-h` or `--help` (handed to `docker login` as an option, in the check and in the app login) and was used as a regex in `grep -v` (a dot matched any character: removing `a.b.io` could delete `axb.io`). It now starts with a letter or digit, `docker login ... -- <host>`, exact match with awk. |
| `config`: set, apply, sync, migrate | config-change.sh | read | ok. The key must be in the settable list; quotes and backslashes are refused; numbers and booleans are matched; the file is checked (`hs config check`) and put back when it fails. **fixed:** a newline in a string value passed the pattern check (`grep -E` on a here-string matches any line) and would have written a second line into machine.toml. |
| `notify`: add, set, remove, test, migrate | notify-change.sh, notify-channel.sh, lib/channels.sh | read | ok. Secrets are stdin; a channel file is read as data (never `source`d). **fixed:** a `--set` value of `@setting:../../x` made `chan_load_text` read an arbitrary file as a setting; the key must be a plain setting name now. |

`READS` (124 rows, all `hs sys <words>` rows of kind read): checked mechanically (tests/web-changes-test.py `WordsThatStartWithADash`) and by
reading the scripts of the free-text arguments. No read takes a value from the client that is not matched by a pattern that starts with a
letter or digit, except `fm ls --path` (checked again by fm.sh, see `fm`), `backup find <word>` (wrapped as `*word*` before restic sees it;
control characters refused) and `logs show --unit` (a value after its option). The reads that take a name (`ct logs/bindings/snapshots/
storage/users`, `node show/keyline/status`, `shares acl/visible/mounts/history`, `users access/details`, `state smart`, `disk results/ls`,
`docker app/rev/logs`, `recipes asks/steps`, `jobs record/tail`, `live raw`) were not each read to the last line; their patterns are
`NAME`/`UNIT`/fixed forms that start with a letter or digit.

Not done: a line-by-line read of the rows marked "outline" or "web pattern only". Not tested on hardware yet: every fix is covered by a test
with fakes that ran on Linux (WSL), none ran on a server.

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
