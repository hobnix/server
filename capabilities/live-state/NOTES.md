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
- The `group` option of `services.redis.servers.<n>` is unverified in the pinned nixpkgs; module.nix does not use it. The socket group is
  `redis-hobnix`; hs-web and hs-live get it through SupplementaryGroups.
