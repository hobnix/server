# Plan: web interface, backend and sign-in

Status: the entry page, the generic read API, the app shell and the Summary page are built; every other page is not. The design is a high-fidelity hand-off ("Homeserver Web UI", with its own
reference of what the server offers); this file records the decisions about how the page talks to the server.

## Decisions

- **Reads and changes are `hs sys ...` calls.** No second data layer. The state database (`state.db`) stays what it is (history: disk inventory,
  events, SMART, hourly samples) and is read through `sys state ...`. Changes are always `plan`, then `start` (with `--confirm <name>` when the plan
  names one), progress is `sys jobs tail`. The plan/start contract already is the API.
- **Backend: Python stdlib, `scripts/web-serve.py`**, one process on the host as root (`hs-web.service`), never in Incus (it has to work while the
  storage is locked). It sets `HS_CALLER=web`.
- **Frontend: Svelte 5 + Vite in `web/`**, built by Nix (`pkgs/hs-web.nix`, `buildNpmPackage`) into static files that the backend hands out. The Nocturne
  stylesheet is `web/src/nocturne.css`; the accent and section tokens are NOT in it, they come from `/theme.css`.
- **Plain HTTP, home networks and Tailscale only** (firewall rule like the status document's). **Never a Zoraxy rule.** A passphrase or password typed
  into the page crosses the LAN unencrypted: that is why it stays off networks you do not trust. TLS (Tailscale serve) is a later step.

## HTTPS through Tailscale (`webTailscale = true`)

The page is plain HTTP by default. With `webTailscale` the page listens on 127.0.0.1 only, `hs-web-tailscale.service` runs `tailscale serve --bg --https=443 http://127.0.0.1:<port>`, and the page is reached at `https://<host>.<tailnet>.ts.net` from devices in the tailnet (certificate from Tailscale; no funnel, no Zoraxy rule; the firewall opens 443 on `tailscale0` only and the LAN port stays closed). The backend then sets `Secure` on the cookie and `Strict-Transport-Security`, and takes the client address for the login throttle from the proxy's `X-Forwarded-For` (only from loopback). Needed once by hand: `sudo tailscale up` on the server and "HTTPS certificates" on in the Tailscale admin console (DNS). Not run on a server yet.

### Reachable on the home network as well (`webLan`, default true)

With `webTailscale = true` the page can still be reached by the server's address on the home network over plain HTTP (the firewall rule for the private ranges stays and the page listens on all addresses); `webLan = false` closes that and binds the page to loopback again. `Secure` cookie and HSTS are decided per request: only a request that comes from this machine itself (that is `tailscale serve`) counts as HTTPS, so a login from the LAN address still works. `webPort` may be 80 (the service is root; nothing else on the host listens there; the containers have their own addresses).

## Sign-in

| Who | How it is checked | When |
| --- | --- | --- |
| Domain Admins member | `ntlm_auth --helper-protocol=squid-2.5-basic` (password on stdin, URL-escaped), then `wbinfo`: the user's group ids must contain the gid of `Domain Admins` | storage open |
| the local `adminuser` | `unix_chkpwd adminuser nonull` as root (password on stdin, NUL terminated); no other local name is accepted | always, the only way in while the storage is locked |

Every other domain user, even with the right password, is refused ("Only members of Domain Admins can sign in"). While `/run/hs/storage-locked` exists
dc1 is down: the domain door is closed and domain sessions that exist stop working.

Protection (tests/web-login-test.py): random session token in a `HttpOnly; SameSite=Strict` cookie (8 h idle, 12 h at most, in memory, so a restart signs
everybody out); every POST needs `Content-Type: application/json`, an `Origin` equal to the `Host`, and after sign-in the `X-CSRF-Token` of the session;
five failed logins in ten minutes lock the client address and the user name for 30 s, doubling to 15 min; a failed login waits one second; the body is
read in full and limited to 4 KiB; user names must match `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`; static files are served from one directory with a
path-traversal check; every response carries a strict Content-Security-Policy. `GET /api/hello` is open (the sign-in page shows three status lines from
`hs sys status`, cached 20 s) and holds nothing but those lines, the lock state and the realm name.

## Theme (machine.toml)

`webAccent = "#rrggbb"` (default `#9184d9`, the purple of the design). `scripts/web-serve.py` derives the whole accent ramp (100 to 900) and the section
ground from it in OKLCH: same lightness steps as the design's ramp, the hue of the chosen colour, chroma scaled by how colourful it is. The default
returns the design's own values. The result is served as `/theme.css`, loaded before the app's CSS. Neutrals and the ground stay as they are. Medium-light
colours read best; a very dark accent will not be readable on the dark ground (not checked by the server).

## Reads (`GET /api/sys/<words>[/<arg>][?query]`)

Behind the session. The allowlist is `READS` in `scripts/web-serve.py`: the words after `hs sys`, the number and pattern of path arguments, the optional
query parameters (each with a pattern; they become `--flag value`), the answer kind (`tsv` becomes `{rows}`, `json` is passed on, `text` becomes `{text}`)
and a cache time. Nothing outside it is ever run, nothing goes through a shell, an argument must match its pattern completely. A test checks that every
entry is a real `sys` row of `scripts/lib/registry.tsv` and that none of them is a changing command. One call per question at a time and a short cache,
so several open browsers cost one `hs sys` call. A failing read is a 502 and is not cached.

## Shell and pages

Top bar, resource tree (`web/src/nav.js`), bottom panel (Tasks, Jobs, Logs, Disk events, Reports; only the visible tab is read) and the page area.
The page is the URL path. Built: **Summary** (meters, disks by pool, status list, from `sys deck`, `sys status`, `sys monitor disks`, `sys ups status`;
CPU and memory are computed from two readings of the document, so the first value appears after the second poll). Also built, read only: **Instances** (list over detail with storage bindings), **Shares** (bulk: list, permissions, snapshots), **Health** (problems with the
command that helps). Built later the same day by parallel agents, read only and never opened against a real server: **Pool** and **Disks** (bulk, fast, unassigned), **Groups**, **Users**, **Backup**, **Snapshots**, **Encryption**, **Vault**, **Network** (instance address map, remote shares, config cards), **Hardware**. Pages are listed in `web/src/routes.js`; a path that is not listed shows the placeholder. Not built: the proxyserver pages (they need a read API on the VPS). Known gaps: no per-disk list of encrypted volumes, no vault usage figure, no Zoraxy/Tailscale/ports/DNS data. The Update and Reboot buttons are disabled until the plan dialog exists. Not built: unlock in the browser (the locked card says `hs unlock`),
a navigation for narrow screens (the tree is hidden below 800 px).

## Design match

All built pages, the shell and the sign-in were compared with the design prototype side by side at 1440x900 and reworked (tree meta counts, bottom panel with drag grip and Reports tiles, restyled plan dialog, per-page headers, cards and tables). Where the design shows something no `sys` command can supply, the element is left out or shows a quiet "not available yet"; buttons for changes that are not wired are drawn disabled with the title "not built yet". Known leftovers: the Network address map has no router view, Health problems have no detail line. Not verified against a real server.

## Changes wired (2026-10-12, not run on a server)

`CHANGES` in `scripts/web-serve.py` (closed list, each argument matched completely): `jobs run|stop`; `ct start|stop|restart|snapshot|update`, `snapshot --label`, `restore|delete-snapshot --snapshot`; `backup now|verify|drill|browse --to|toggle --name --kind --to|offsite-now|offsite-off`; `shares <s> snapshot|repair|backup|cache|auto --to|rollback --snapshot`; `users <u> lock|unlock`; `system sync|scrub|update|gc|rollback [--pool]`; `config set <key> <value>` (keys in `CONFIG_KEYS`, kept in step with `scripts/lib/config-keys.sh`). Not offered on purpose: disk setup (`backup init`), off-site credentials, passwords, user and share delete, pool changes, `ct delete`, reboot. A plan with status `needs` is not supported by the dialog. The plan dialog also shows the `section` and `text` lines (the update preview lists the new commits).

New data commands: `hs sys expiry list`, `hs sys pc list`, `hs sys recipes list`, `hs sys config list|check`, `hs sys config plan|start set` (scripts/recipes-list.sh, config-read.sh, config-list.py, config-change.sh, pc.sh --list, expiry.sh --list). Pages: Expiry dates, Game streaming, Apps, Settings.

## Create dialog and forms

`web/src/shell/CreateDialog.svelte` is the shared dialog of the design's create flows: a form component renders it with its fields (snippet `form`), `args` (a function of the form state that returns the argument list of `hs sys <area> plan|start`, or null while the form cannot name a command yet) and optionally `stdin` (a password or passphrase, one line). The dialog asks for a plan 300 ms after the last change and shows allowed / needs input / refused with the server's own `needs`, `reason`, steps, command and confirm word. Open a form with `openCreate(Component, props)` (web/src/ui.svelte.js). `CHANGES` entries may be a dict `{fixed: [patterns], opts: {--flag: (pattern|None, repeats)}, stdin: bool}`: options follow the fixed arguments in any order; `stdin` is only accepted for entries that say so, it is never part of `args` and never logged.

## Forms and further actions (2026-10-12, not run on a server)

Built on the create dialog: users and groups (new user and set password with the password on stdin, new group, membership, delete, flush caches), shares (new share, permissions, rename, delete, restore, purge a kept folder), instances (create, settings, fixed address, bind and remove storage, delete), pools and disks (add disks in its three variants with an optional LUKS passphrase on stdin, adopt, replace, remove, short and long self-tests through the new `scripts/disk-change.sh` and the rows `sys disk plan|start`), reboot and shutdown (`system-change.sh`, scheduled five seconds ahead so the answer returns; the plan refuses while a backup, sync, scrub or pool change runs and warns that encrypted storage comes back locked), Wake (`scripts/pc-change.sh`), expiry add and remove (`scripts/expiry-change.sh`), the unlock endpoint `POST /api/unlock` (passphrase on stdin only, only while locked, five failures lock it for a while), and a slide-over menu for the tree below 800 px. Every successful `start` clears the read cache. Left out: convert a pool, Update all (no `sys` row), instance network profile and bindings inside Create, group choices in New user and per-share levels in New group (the commands have no such option), SSH keys, search.

## Search, proxyserver, SSH keys, convert, update all (2026-10-12, not run on a server)

- **Search** (`web/src/shell/Search.svelte`, `web/src/select.svelte.js`): client side only; the lists are read when the box first gets focus; a result opens its page with the item preselected; `/` focuses the box.
- **proxyserver pages** (`/proxy`, `/proxy/tailscale`, `/proxy/settings`): `GET /api/proxy/status` fetches the one URL from `proxyStatusUrl` (machine.toml, off by default; no request parameter can change it; 5 s timeout, 8 s cache, no redirects, at most 256 KiB, must be a JSON object). Only keys that the VPS status document has today are shown. Missing for the design's cards, to be added to the VPS document in the proxyserver repo later: oldest queued mail age, queue rows, stalwart reachability, SPF state; watcher state, heartbeat age, watched sites with answer code and since; game port blocks with counts and the wings probe; certificate days left, config revision (git hash and subject), OS and region; Tailscale address, tag, latency, the 'may reach' ACL rows; the `machine.nix` keys (secrets as file paths only). The tree rows of the proxyserver have their own paths and dots (see "Proxyserver rows, header and live tasks" below); the keys are listed exactly in "The VPS status document".
- **SSH keys** (`hs sys ssh-key list`, `ssh-key-change.sh`, area `ssh-key`): add one public key (strict pattern, no option prefixes) or remove one (red plan; the last key and the key of the current SSH session are refused). The change only edits `sshKeys` in machine.toml and takes effect with `hs rebuild`.
- **Convert** (Pool members, SnapRAID only): `manage-pool.sh --convert` reformats ONE data disk with another filesystem or with LUKS (its files move to the other data disks first, parity catches up at the next sync); red plan, the disk name is the confirm word, the passphrase goes on stdin.
- **Update all** (`ct all update-all` in `ct-change.sh`): the plan lists the running containers (VMs are left out), start updates exactly those.

## Terminal (`webTerminal = true`, off by default; 2026-10-12, not run on a server)

A shell in the browser: the top bar's Terminal button opens one on the server (as `adminuser`, like an SSH login; it also works while the storage is locked, which is how you run `hs unlock`), the Instances detail has one inside the instance (`incus exec <ct> -- bash`, falling back to `sh`). `scripts/web_terminal.py` holds a hand-written RFC 6455 WebSocket and the session pump; the glue in `scripts/web-serve.py` is `POST /api/terminal` (session + CSRF + Origin, returns a one-use 30 s ticket bound to the session and the target) and `GET /api/terminal/ws?ticket=`. The shell is started through a pty as a transient systemd unit (`systemd-run --pty --collect --wait --send-sighup --unit hs-web-term-<id> -p User=<local user> ...`), NOT inside hs-web: that unit has NoNewPrivileges and a private /tmp, which would break `sudo`. Limits: 4 terminals in total, 2 per session, 30 min idle, 8 h at most, ended with the web session (logout, expiry, a domain session when the storage locks); instance terminals are refused and torn down while locked. The log has one open and one close line, never the keystrokes. The CSP allows the websocket of the page's own host only. The frontend uses xterm.js (lazy chunk). Not verified: the real pty and `systemd-run --pty` as adminuser, `sudo` and zsh inside, `incus exec` from the transient unit, the websocket through `tailscale serve` (tests/web-terminal-pty.sh checks the real pty on Linux).

## Gaps closed (2026-10-12, not run on a server)

- **Backup page:** "Restore files..." (`web/src/forms/backup/RestoreFiles.svelte`) is the share restore: `shares <share> restore --snapshot <id|latest> [--path ...]` (share-change.sh, which runs `hs backup restore`), so the files land in the share `restored` and only that subtree changes owner. "Copy off-site now" and "Switch off" show when an off-site repository is set (`backup offsite-now|offsite-off`, already allowed). Setting the repository (`offsite-set`) stays a terminal job on purpose: an address can carry a password (`rest:https://user:pw@host`) and would travel through argv and the job log; `backup-change.sh` also refuses an address that starts with a dash or holds `..`.
- **Disks page, "Other disk":** `disk-change.sh` gained `temp-mount <partition> [--name]`, `temp-copy <name> --to <share>` (a background job) and `temp-eject <name>`; the rows `sys disk plan|start` are the same, the list is `sys temp-disk raw` (already a read). The partition must be one `temp-disk.sh raw` offers; read-only is the only mode.
- **Health page:** a problem gets a Plan button where one safe flow exists (`web/src/pages/Health.svelte`, `FIXES`, keyed on the texts of health-check.sh): backup now, restore drill, off-site copy now, scrub of a ZFS pool or of bulk, eject a temp disk. Everything else keeps its pointer text only.
- **Network page:** new reads `sys unifi networks` and `sys unifi clients` (unifi.sh; the old `unifi used|reserved` reads needed an address argument and are removed from `READS`), `sys ports list` (`hs ports --list`, exit 1 with warnings is still an answer), `sys dns list` (`dns.sh raw`). New change area `dns` (`sync`) through `dns-change.sh` (`sys dns plan|start`; plan from `dns.sh sync --plain`, start is the job `dns.sh sync --yes`). The page shows the router's networks, marks addresses the router has reserved or sees online on the address map, lists the Zoraxy rules with admin-interface warnings, the DNS names and (button "Open ports") every listener. "Offer a share" stays disabled: `hs remote offer` prints the new login's password once, which would end up in the job log.
- Tests: `tests/web-gaps.sh` (+ `web-gaps-test.py`), `tests/dns.sh`, `tests/backup-change.sh`.

## VPS buttons (`vps update`, `vps watch`; 2026-10-12, not run on a server)

Built: `sys vps plan|start update|watch` (`scripts/vps-change.sh`; `CHANGES["vps"] = [[r"^(update|watch)$"]]`, nothing else is a parameter) and `hs vps key` (`scripts/vps.sh`). `start` runs `ssh -i /var/lib/hs/vps-key -T -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/lib/hs/vps-known-hosts ... root@<vpsHost> <verb>` as a background job (`hs_job`, unit `hs-job-vps-<verb>-HHMMSS`, so the output is the Tasks log and a failure notifies). `vpsHost` in machine.toml (default off) reaches hs-web as `HS_WEB_VPS_HOST` and the session answer as `features.vps`; the buttons in `web/src/pages/proxy/ProxyHead.svelte` are grey without it. The private key is the vault secret `vps-key` (in `vault_default_secrets`, `secrets.sh`, `vault.sh uses`), created only by `hs vps key` (ssh-keygen in /run, written through the vault link, root only); web-serve.py never names or reads it, the ssh command line holds only its path, a closed vault makes the plan answer `refused: run hs unlock`. `status` is not offered (no read-only use for it in the interface). The VPS side lives in the proxyserver repo (branch `claude/vps-remote`): machine.nix `webKey` becomes a root key with `restrict,command="vps-remote"` (modules/ssh.nix), and `modules/cli/vps-remote.sh` accepts exactly `update`, `watch`, `status` from `$SSH_ORIGINAL_COMMAND` (exit 2 and a journal line otherwise). Setup steps: docs/web-interface.md section 7. Tests: `tests/web-vps.sh` (+ `web-vps-test.py`) here, `scripts/vps-remote-test.sh` there. Unverified: a real SSH connection, the NixOS build of the forced command on the VPS, the closed-vault path (needs symlinks; skipped on Windows). The ssh call uses port 2222: the VPS runs Tailscale SSH (`--ssh`), which answers port 22 of the tailnet address itself and would bypass the key's forced command; sshd listens on 2222 as well (proxyserver modules/ssh.nix) and only OpenSSH serves it.

## Not built yet

- More areas in `CHANGES` (web-serve.py): wired today: `jobs run|stop` (Run now in Jobs, Run health check on the Summary) and `ct start|stop|restart|snapshot [--label]` (buttons on the Instances page). `POST /api/plan` and `/api/start` need session + CSRF, the plan dialog shows the plan, a danger plan needs its confirm word; the Tasks tab follows the job with a server-sent-events stream (`GET /api/sys/jobs/stream/<unit>`), polling `sys jobs tail` every 2 s as the fallback.
- All other pages, in the design's order.
- Missing `sys` rows (from the design hand-off): a stdin password command for users, recipes, settings writes.
- Unverified on a real server (this was written on a PC without Nix and without a domain): the `ntlm_auth`, `wbinfo` and `unix_chkpwd` calls, the NixOS unit,
  and the `npmDepsHash` in `pkgs/hs-web.nix`.

## Speed (no database)
- Reads are stale-while-revalidate: an answer older than its ttl but younger than min(10 x ttl, 5 min) is returned at once (header `X-HS-Age`) and refreshed in the background, one run per question; errors keep the old value; ttl 0 reads and the cache clear after a start are unchanged (a refresh begun before the clear does not store its answer).
- `Warmer` (started by `main()`) reads the `WARM` list one after the other every few seconds while a session was seen within 5 minutes and the storage is open.
- Frontend: `poll()` keeps the last answer per path (shown at once, then refreshed); Shell prefetches the main pages' reads when idle. Cleared on sign-out.
- Sessions are written to `/run/hs-web/sessions.json` (0600, directory 0700 from `RuntimeDirectory`, preserved over restarts): only sha256 of the cookie token, user, realm, times. The CSRF token is derived from the cookie token (`csrf_for`), so it is not stored either. A reboot clears them.

## Proxyserver rows, header and live tasks (2026-10-12, not run on a server)

- **Tree rows**: Mail entry `/proxy/mail`, Ports `/proxy/ports` (alias `/proxy/game-ports` for old links), Outside watcher `/proxy/watcher`, Certificate `/proxy/certificate`; Mail entry, Outside watcher and Certificate show the proxyserver page scrolled to (and outlining) their card; Ports has its own page (`web/src/pages/ProxyPorts.svelte`, a tree-table in the look of the Summary page's Disks card: group rows Games -> pelican-wings, Matrix calls (LiveKit) -> livekit, Mail -> stalwart, This server's own ports, their blocks indented underneath, columns Name, Proto, Ports, Count, Target, Status, and a footer line with the totals). Each row has a status dot (the tooltip says why) computed by `web/src/pages/proxy/status.js` from the VPS document, with the same functions the cards use, so dot and card agree: grey = key missing, green, amber, red. The `proxyserver` row itself: red when `/api/proxy/status` fails, amber for a document older than 5 min or `problems > 0`, green otherwise; the Tailscale row is green for `Running`. The search entries come from the tree, so they follow. `tests/web-proxy-status.mjs` (run by `tests/web-proxy.sh`) checks the rules and that every row has its own path and a route.
- **Header**: the name beside the brand is `host` of `sys deck` (the same cached document every page header uses); "N nodes" is 1, plus 1 while `GET /api/proxy/status` answers. The Update button carries a count tag from the new read `hs sys system updates` (`scripts/system-updates.sh`): rows `behind <n>`, `ahead <n>`, `upstream <ref>`, `fetched <epoch>`, taken from refs that are already fetched (`git rev-list --count HEAD..@{u}`); it never runs `git fetch`, so the number is as old as the last `hs update`, `hs update --preview` or manual fetch. Test: `tests/system-updates.sh`.
- **Live tasks**: `GET /api/sys/jobs/stream/<unit>[?from=N]` (session, unit pattern `UNIT`, `from` digits) answers `text/event-stream`: one `data: {"rows": [...]}` per look at `hs sys jobs tail` (the same rows as the read; sent when there are new lines, an exit or a state change), `: ping` on every 15th quiet look, and `event: end` when the unit finished (`ok`/`failed`), stayed `unknown` for 4 looks, the session ended (sign-out, expiry, storage locked) or after `HS_WEB_STREAM_HOURS` (6). One look every `HS_WEB_STREAM_EVERY` seconds (1); at most `HS_WEB_STREAM_MAX` (6) streams at once (503 beyond), one thread each, the counter under a lock. The page (`follow()` in `web/src/ui.svelte.js`) uses `EventSource` and falls back to the 2 s polling of `sys jobs tail` on any error or when the stream ends while the task still runs (a browser reconnect would restart from the old offset). Tests: tests/web-login-test.py (stream cases).

## The VPS status document (what the proxyserver pages read)

`GET <proxyStatusUrl>` (the proxyserver's `deck-serve.py`, port 9740 over Tailscale) must return one JSON object of at most 256 KiB. The pages read exactly these keys and ignore the rest (unknown top-level keys are listed under "More from the VPS"); every key is optional, a missing key leaves the dot grey and the card saying "Not available yet". Times are Unix seconds, durations are seconds. A value of the wrong type is ignored, never an error.

| Key | Type | Used for |
| --- | --- | --- |
| `schema`, `kind` | `1`, `"proxyserver"` | not read by the pages |
| `host` | string | name in the page header |
| `time` | number (epoch) | age of the document: older than 300 s = "status is old", amber dot on the node row |
| `uptime_s` | number | header line "up ..." |
| `load` | `[1m, 5m, 15m]` numbers | header line, CPU card |
| `cpu` | `{total, idle}` counters | CPU meter (difference of two readings) |
| `mem` | `{total, available}` bytes | memory meter |
| `pools.system` | `{size, used}` bytes | system disk meter |
| `net` | `{iface, rx_bytes, tx_bytes}` | public network row |
| `net_tailscale` | `{iface, rx_bytes, tx_bytes}` | Tailscale meter and page |
| `tailscale` | string (`"Running"` = fine) | Tailscale meter, dot of the Tailscale row |
| `problems` | number | health chip, node dot (amber when > 0) |
| `failed_units` | number | "Failed units" row |
| `history.hours` | list of `{cpu, mem}` (one per hour, 24) | sparklines |
| `mail_queue` | number | queue size (older documents; `mail.queue` wins) |
| `mail` | `{queue, oldest_s, stalwart, spf, last_delivery}` | Mail entry card and dot. `queue` number, `oldest_s` age of the oldest queued message (null when empty), `stalwart` bool (does it answer), `spf` string (`"pass"` = fine, anything else amber), `last_delivery` epoch. Red: `stalwart` false; amber: `oldest_s` over 3600 or `spf` not `pass`. |
| `watcher` | `{state, heartbeat_age_s, sites: [{name, url, code, since}]}` | Outside watcher card and dot. `state` is `"ok"`, `"alert"` or `"stale"`, `code` the last HTTP answer (null = none), `since` epoch of the last change. Red: `state` `alert` or a site with no `code` or a 5xx (any other answer, also 403 or 404, counts as reachable, like hs-watch.sh); amber: `state` `stale` or `heartbeat_age_s` over 900. |
| `game_ports` | `{blocks: [{name, proto, ports, count, forwarded}], wings: {ok, ms}}` | Old list (kept until the VPS stops emitting it; the web interface no longer reads it). `proto` is `"tcp"`, `"udp"` or `"tcp+udp"`, `ports` a string like `"25565-25575"`, `count` the number of ports, `forwarded` bool. Red: `wings.ok` false; amber: a block with `forwarded` false. |
| `ports` | `{groups: [{id, name, target, probe, rows: [{name, proto, ports, count, forwarded}]}]}` | Ports page, the Ports card and the dot of the Ports row. `id` is `"games"` (-> pelican-wings, rows from gamePorts as tcp+udp, gameTcp, gameUdp), `"rtc"` (-> livekit, rtcTcp / rtcUdp, only when rtcIp is set), `"mail"` (port 25, not forwarded: Postfix on the VPS accepts it and relays to stalwart) or `"own"` (80 for the certificate check, 41641 udp for Tailscale; not forwarded). `target` is a name or null, never an IP. `probe` is `{ok, ms}` or null: wings for games, livekit (one TCP connect to the first rtcTcp port) for rtc; a timeout is not ok, a refusal is ok. `forwarded` is read from the live nft ruleset (dnat rules for games and rtc; accept rules of the inet filter input chain for mail and own, where true means open on the VPS itself), null when nft cannot be read. Red: a probe with `ok` false; amber: a row with `forwarded` false; grey: key missing or nothing known. |
| `certificate` | `{days_left, domain}` | Certificate row and dot: red under 7 days, amber under 21. |
| `revision` | `{hash, subject}` | "Config revision" row (git hash and subject of the VPS configuration) |
| `os`, `region` | strings | "System" row |
| `tailscale_info` | `{address, tag, latency_ms, may_reach: [{target, ports}], never_reach: [{target, why}]}` | Tailscale page: address and tag, latency, the two access lists |
| `settings` | object `{key: value}` | Settings page: the `machine.nix` keys; secrets as file paths only, never values |

The code that reads them is `web/src/pages/proxy/status.js` (dots and sections), `web/src/pages/Proxy.svelte`, `ProxyTailscale.svelte`, `ProxySettings.svelte` and `proxy.svelte.js` (`KNOWN` = the top-level keys that are not echoed). A key the pages do not read shows up under "More from the VPS" as a raw value until a card exists for it. The proxyserver repo keeps copies of `deck-serve.py` and `deck-status`: change both.
