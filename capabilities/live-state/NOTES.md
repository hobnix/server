# live-state

Redis on a unix socket plus the collector `hs-live`. The collector runs `hs sys <topic>` on an interval and stores the raw text in Redis; the
web interface serves topic reads from there and pushes changes to the browser (`/api/events`). Not tested on hardware yet.
Design: docs/PLAN-web-cache.md. Option `liveState` ("redis" | "off", default "off"); on when `webUi` and a homeserver and `liveState = "redis"`,
or when `live-state` is named in `capabilities`.

Rules:
- **One writer:** only `hs-live` (scripts/live-collect.py) writes the topic keys. The web only reads and asks for a refresh.
- **Never TCP:** `port = 0`, the socket /run/redis-hobnix/redis.sock (mode 660). No firewall rule.
- **Never persistent:** no `save`, no append file; Redis is a cache in RAM (32 MB, allkeys-lru). A reboot starts empty and the collector refills it.
- **503, not a fallback:** with Redis down a topic read answers 503 "state service down"; the web never runs the read itself in this mode.
- **Names:** key `hs:v1:<topic>` (JSON: ts, gen, rc, out, err, ts_err; `out` is the raw text), channel `hs:v1:changed` (`<topic> <gen>`),
  channel `hs:v1:refresh` (`<topic>` or `*`). Topics: scripts/lib/live-topics.tsv.
- **The `live` topic:** `hs sys live status` is collected every 5 seconds as topic `live`. The command runs before the collector takes its
  own Redis lock or issues its own GET/SET, so the `live` row in the Diagnostics table reports the previous collection; this is expected,
  not staleness. The old database collector (`scripts/reads-collect.sh`) remains for the reads that still use it.
- The `group` option of `services.redis.servers.<n>` is unverified in the pinned nixpkgs; module.nix does not use it. The socket group is
  `redis-hobnix`; hs-web and hs-live get it through SupplementaryGroups.

Topics (58, including `status` and `live`): see `scripts/lib/live-topics.tsv`. Storage fixed reads now have their own topics, including
six fixed-pool topics (`pool-info-bulk`, `pool-info-fast`, `pool-members-bulk`, `pool-members-fast`, `pool-state-bulk`,
`pool-state-fast`) whose words contain the literal pool name. The web resolves those per request from the validated
`pool=bulk|fast` query; any other pool argument stays a direct read. Lock mode is `skip` for mounted-pool/Samba reads
(`pool-info-*`, `pool-members-*`, `shares-overview`, `shares-deleted`, `shares-principals`) and `run` for the rest, so
lock-aware pages keep their defined locked state. The old database collector and `reads` table remain for off mode and
unmapped reads.

Refresh base (built, not run on hardware):
- **Columns 5 and 6 of live-topics.tsv:** `cap` (the capability that must be on, `-` = always; a topic whose cap is off is not run, has no document and
  is skipped by `hs sys live check`; `live_state.cap_on`, cached 60 s) and `groups` (comma list of change areas, `-` = none).
  `ls.topics()` still returns 4-tuples; `ls.topic_info()` returns `{topic: {cap, groups}}`.
- **Groups:** a refresh `@<group>` wakes every topic that lists the group or `any`. Group names are the registry `topic:` words
  (`backup disks docs instances jobs network security shares system users`) plus `ext-<name>`. `*` / `--all` stay for unlock and job end.
  A web start refreshes `@<group>` of its area (`AREA_GROUP` in web-serve.py, unknown area: `*`).
- **Parallel limit:** the collector runs at most `HS_LIVE_PARALLEL` (default 4) `hs sys` reads at once.
- **CLI hook:** scripts/lib/hs.sh runs a registry row with flag `changes` as a child and, after exit 0, calls `live_refresh @<topic flag>`
  (default `@system`); other rows still `exec`. `hs_job` refreshes `@jobs` at start and everything at the end. Test knob `HS_LIVE_LOG`
  (lib/live.sh): append the arguments to that file instead of using the socket.
- **Old collector:** in Redis mode (the live socket exists) `reads-collect.sh` skips a read whose words equal the words of a topic.
- **Topic map:** the session answer carries `features.topics` (read URL -> topic, empty in off mode); `poll(path, ms)` uses it when it has no
  topic argument.

System slice (built, not run on hardware): 17 more topics for the Summary, top bar, Health, Settings and Jobs: `deck`, `jobs-running`, `jobs-list`,
`health-next`, `health-list`, `hardware`, `ups`, `system-updates` (skip while locked), `system-config`, `setup-list`, `config-list`, `parts-list`,
`node-list`, `ssh-keys`, `expiry`, `notify-channels`, `notify-providers` (the last two need the `notifications` capability). Explicit refreshes
outside the dispatcher: `health-check.sh` (real run: `health-next health-list status deck`), `ups.sh event`
(`ups deck status`), `jobs.sh stop` (`@jobs`), `update.sh` and `update-preview.sh` after the fetch (`system-updates`).

Instances slice (built, not run on hardware): 8 more topics, all `skip` while locked: `ct-list` (10 s), `ct-profiles` (120 s) (both need the
`incus` capability), `services-list`, `services-app`, `services-routes` (30 s), `services-local-routes` (needs `gateway`), `services-tiles` (60 s)
and `services-stats` (30 s; both need `dashboard`; stats calls the service APIs, keys go on curl's stdin). A topic whose capability is off is read
directly by the web (no Redis document). Groups: `@instances` (any `ct`/recipes/mac change) and `@network` (services, routes, net, gateway) wake the lists, `services-app` and the routes; `ct-profiles` and `services-local-routes` also listen to `@system` (`hs rebuild`/`update` change the Incus preseed and the proxy); `services-stats` only to `@network`. No new explicit hooks: every
change of these areas goes through the dispatcher or a web `start`. `ct <ct> ...` and `services show` stay direct.

Apps slice (built, not run on hardware): 3 more topics, all local reads (from the last `hs pkg fetch`, no network): `pkg-market` (120 s, `skip`;
groups `system,instances`), `pkg-repos` (300 s, `run`; `system`) and `recipes-list` (60 s, `skip`, needs `incus`; `instances,system`).
`pkg fetch|install|update|remove|repo add|remove` change the package tree: the dispatcher asks for `@system`, and `pkg.sh` itself refreshes
`pkg-market pkg-repos recipes-list parts-list` after success (a fetch always, one repository may have failed while the others moved), so the
web `pkg` area and a job both reach them. A recipe run (`@instances`) changes the applied version and the installed state, hence `instances` on
the market and the recipe list; `hs update`/`rebuild` pull a new tree (`@system`). `parts list` and `system updates` are slice 2 topics. No
timer runs `hs pkg fetch` (checked in `config/*.nix` and `capabilities/*/module.nix`).
`parts-list` also listens to `@network`: a gateway or vps web start runs a rebuild that can switch a part on.

Network slice (built, not run on hardware): 8 topics, all `skip` while locked (they need Incus, the proxy or Samba): `gateway-status` (60 s),
`gateway-routes` (60 s), `gateway-health` (300 s), all cap `gateway`; `dns-list` (300 s, cap `ad`: `dns list` fails without `adDomain`);
`unifi-networks` (300 s) and `unifi-clients` (60 s), cap `network` (`unifi.sh` exits 2 without setup); `ports-list` (120 s); `remote-list` (60 s).
Groups: the gateway, DNS, UniFi and port reads wake on `network` (net, routes, services, gateway rows), `instances` (a container start, stop
or removal changes routes, addresses and listeners; `unifi-networks` does not list containers, so it skips this) and `system` (config set,
rebuild, update, preset and extension rows can change the domain, ports or a capability). `remote-list` wakes on `shares` (all `remote *` rows;
the `hs-remote-mount` timer already ends with `live.sh refresh @shares`), `network` and `system`. No new explicit hooks: every change reaches
them through the dispatcher. No secret reaches a topic: `dns.sh` and `unifi.sh` read their credentials themselves and print none. The UniFi
and gateway-health reads call the router or the proxy on their interval even with nobody watching; the long intervals are the limit.
