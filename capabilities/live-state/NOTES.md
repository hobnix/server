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

Topics (22, including `status` and `live`): see `scripts/lib/live-topics.tsv`. Storage fixed reads now have their own topics, including
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
