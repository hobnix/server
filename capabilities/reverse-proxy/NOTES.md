# reverse-proxy

The capability that publishes the services (descriptors in /var/lib/hs/services.d, `hs services`) on a reverse proxy. A proxy is a
VARIANT: a script `scripts/providers/reverse-proxy/<variant>.sh` with four verbs (`info`, `list`, `ensure <host> <path> <target>`,
`remove <host> <path>`; see the header of zoraxy.sh). The runtime setting `reverseProxy` names the variant and switches the
capability on; `proxyDomains` lists the domains it serves (a service "jellyfin" is wanted as jellyfin.<domain>).

- **Public or private.** `info` says whether the proxy is reachable from the internet (`public=yes`). Our Zoraxy is: the Cloudflare
  tunnel sends the wildcard to it. The guard (scripts/services.py `make_plan`): on a public proxy a `never-public` or `private-ok`
  service gets no route, a `public-ok` one needs a typed confirmation, and `public_paths` limit what a public route may reach (the
  root is a dead end, 127.0.0.1:1). On a private proxy (LAN only) everything is allowed. This is how "admin pages never get a Zoraxy
  rule" and the two exceptions (Arcane webhook path, Uptime Kuma status page) are kept: as descriptors, not as rules in a person's head.
- **zoraxy** (the first variant) has two modes. READ-ONLY: it reads the rule files in the container (the same files `hs ports` reads;
  field names differ between versions, scripts/providers/reverse-proxy/zoraxy-list.py is tolerant). API (4b-1), once `hs services proxy login`
  has put the admin login in the vault secret `zoraxy-admin`: Zoraxy (3.3.5 here) has no API keys, only a session cookie from
  `POST /api/auth/login` (form username, password, rmbme), so every provider call logs in first. Zoraxy 3.3.x also protects every POST with a CSRF token (gorilla/csrf, found out on the
  real server: "Forbidden - CSRF token not found in request"): `GET /login.html` sets the cookie `zoraxy_csrf` and carries the token in
  `<meta name="zoraxy.csrf.Token" content="...">`, which goes back in the header `X-CSRF-Token` of every POST (login included).
  The password goes to curl on stdin, never into an argument and then uses `POST /api/proxy/list` (type=host), `/api/proxy/add` (type=host, rootname, ep), `/api/proxy/vdir/add`
  (type=host, endpoint, path, domain = target + path). Answers are `"ok"` or `{"error": ...}`. Changes apply live, no restart. The provider's
  `check` compares the API list with the rule files (the default site, host `*`, is left out: `type=host` does not list Zoraxy's "root"
  rule, 31 API routes against 32 files on the real server); plan shows a `warn` row and `apply` refuses when they differ (the API of another
  version may not behave like the sources this was written from). `ensure` adds, and since 4b-2 changes: a route that is there with the same target is a no-op; another target is changed
  ONLY if hs made or adopted the route (root: `upstream/add` of the new origin, then `upstream/remove` of the old, so the host is never without
  one; path: `vdir/edit` with type=host, vdir=<path>, path=<host>, domain=<target+path>), else refused (exit 4: adopt it first); a path whose
  host root is missing is refused (exit 5). `remove` (only routes hs made or adopted, exit 6 otherwise; a route that is already gone is exit 0):
  a path via `vdir/del` (type=host, vdir=<path>, path=<host>), a host root via `/api/proxy/del` (ep=<host>), and not while the host still has
  paths (exit 7); apply removes paths before their root. Ownership: /var/lib/hs/services.state/zoraxy.created (what ensure made) and
  zoraxy.adopted (`adopt`, from `hs services adopt`); `owned-list` prints them, the plan shows `remove` rows for owned routes no service
  wants any more and "not adopted" notes for matching hand-made ones. tests/zoraxy-fake.py stands in for Zoraxy.
  Known rules the descriptors do not own show up as `unmanaged` in `hs services plan`, and are never removed.
- **caddy** comes after 4b-2 (4c): a snippet folder plus reload, fully automatic.
- `hs services import` makes descriptors from the routes the proxy has today (found on the real Zoraxy 3.3.5):
  a real root target is one service; a root to an admin page (container+port pairs `ADMIN_TARGETS` in services.py: Arcane docker:80,
  Zoraxy :8000, Grafana, Kuma's dashboard :3001) is never-public, any other app is public-ok (docker runs many apps);
  paths to ANOTHER real target are a service of their own with those `public_paths` (Matrix and the Kuma status page share the apex
  host, JMAP sits next to the webmail); a path to the dead end 127.0.0.1:1 under a real root becomes `blocked_paths` of the root's
  service; the path `/outpost.goauthentik.io` to the container `authentik` becomes `auth = "authentik"` of the root's service (no
  service of its own); the default site (Zoraxy writes it as host `/`, shown as `*`) is no service. A route that belongs to no service
  stays `unmanaged` and is never removed. Zoraxy headers are not imported (not read from the rule files).
- **Paths, auth and headers** (phase 1 of .work/services-paths; public proxy only, the local slot ignores them): descriptor keys
  `blocked_paths` (go to the dead end, strong: they beat a real target of another service, which gets a `conflict` row), `auth`
  (`authentik`, the outpost is the service named `authentik`; missing = `blocked` row and the service gets no route), `auth_skip`,
  `request_headers`, `response_headers` (`"Name: value"`, at most 8, NOT secrets: the file is 0644), `admin` (set by `declare` for
  never-public recipes; public-ok then needs `public_paths`). Recipes say them with `service_path|service_auth|service_header` before
  `declare_service` (api level 2). The provider's `info` may print `features` (comma list of `paths,headers,auth`; missing = `paths`).
  For every header or auth the provider cannot render, the plan has a `manual` row (same columns, target `-`; apply leaves it alone, it
  is not counted as work). Zoraxy says `features paths`: blocked paths are vdirs to 127.0.0.1:1, headers and forward auth are set by hand.
  `cleared = ["auth", "public_paths"]` remembers an offer a person switched off (`edit --auth none`, `--clear public-path`): declare
  does not set it again; giving `--auth authentik` / `--public-path` again removes the mark. `--public-name` raises a never-public service with
  public paths only when the recipe says `--admin`; a never-public a person set stays so.
  A nested path of another service on one host gets the note `inside /p of X: the longer path wins`. Not tested on hardware yet.

## Rules for working on it

Moved from CLAUDE.md (step 8 of docs/PLAN-modular-core.md); these are the rules for working on this part.

**Services and the reverse proxy** (step 4a, docs/PLAN-modular-core.md): a service is a file /var/lib/hs/services.d/<name>.toml (container or host + port, `names`, `exposure` never-public|private-ok|public-ok, `public_paths`, `[want]`); `hs services list|check|plan|add|remove|import` (scripts/services.sh over scripts/services.py, which has the format and the guard). The capability `reverse-proxy` is switched on by the runtime setting `reverseProxy` (a variant = scripts/providers/reverse-proxy/<variant>.sh with `info|list|ensure|remove`; today only `zoraxy`: READ-ONLY (reads the rule files like `hs ports`) until `hs services proxy login` stores the Zoraxy admin login in the vault secret `zoraxy-admin`, then api mode: Zoraxy has NO API keys, only a session cookie from POST /api/auth/login, so the provider logs in per call (first GET /login.html for the CSRF cookie `zoraxy_csrf` and the token in its `zoraxy.csrf.Token` meta tag, sent back as header `X-CSRF-Token` on every POST; password on curl's stdin) and uses /api/proxy/list|add|vdir/add; `hs services plan` compares API and rule files and `apply` refuses when they differ); `proxyDomains` lists the domains. An admin page (container+port in `ADMIN_TARGETS` of services.py: Arcane docker:80, Zoraxy :8000, Grafana, Kuma's dashboard) cannot be described as public-ok without `public_paths`: `hs services add` refuses it. **Editing** (web: the pencil in the Services table; `hs services edit <name> ...`, `hs sys services show <name>` for the form, `hs sys routes plan|start edit <name>`): a merge, only the options given change (`--clear title|icon|group|description|names|public-path` drops one, `--want none` switches off the wants the form owns, reverse-proxy and dashboard), so fqdn, scheme, health and other wants stay; it writes the file only, `apply` makes the route, and going to public-ok needs the typed service name like add. A recipe that declared the service refreshes container, port and title when it runs again (no marker tells which services those are, the plan says so for every edit). The default site of Zoraxy (rule host `/`, shown as `*`) is not in the API's host list, so the API-vs-files self-check leaves it out. The guard: on a PUBLIC proxy (Zoraxy: the Cloudflare tunnel sends the wildcard to it) never-public and private-ok services get no route and public-ok ones need a typed confirmation; `hs services plan` shows `violation` for a route that breaks it. `hs services import` makes descriptors from the routes the proxy has (a root to an admin page, by container+port: never-public; other apps public-ok; paths to another target = a service of their own with `public_paths`; a path to the dead end 127.0.0.1:1 only blocks; the default site `*` is no service). `hs services apply [--dry-run] [--confirm <host or service>]` does what the plan says: `add`, `confirm` (publish on the internet), `change` (another target) and `remove` (a service is gone); confirm, change and remove need the typed host name (or `--confirm`). `hs` only ever changes or removes routes it MADE or that were ADOPTED (`hs services adopt`: the hand-made routes that match a service; lists in /var/lib/hs/services.state/zoraxy.created|adopted); every other route stays `unmanaged`, and a change to a route that is not ours is left alone.

**Recipes declare their service** (4e): a recipe with a web page ends with `declare_service <name> <title> <icon> [private-ok|never-public] [group] [description]` (scripts/recipes/_lib.sh; every recipe with a web page of its own: tests/recipes-declare.sh fails for a new one without the call and names the few exceptions; admin pages and download tools are `never-public`, none is public-ok, except one whose person typed a public host name: `SERVICE_PUBLIC_NAME=<fqdn>` before `declare_service` = `declare --public-name`, upload-storage; it sets the fqdn, raises private-ok to public-ok (never-public stays) and wants reverse-proxy; the route still needs `hs services apply` and its typed confirmation): it writes/refreshes the descriptor (`hs services declare`, which keeps what a person decided and never makes a service public) and asks, once per provider that is set up and remembered in recipe-<ct>.conf, "show it on the dashboard?" (default yes) and "put it on the reverse proxy?" (default no); admin UIs are `never-public`.

## Two slots

There are two proxy slots, independent of each other. `public` is the runtime setting `reverseProxy` (zoraxy) and a descriptor's `[want] reverse-proxy`. `local` is Traefik of the capability `gateway` (capabilities/gateway/NOTES.md), present exactly when that capability is on, and a descriptor's `[want] local-proxy`. `hs services plan|apply|import|adopt --proxy local` works on the local slot; the local provider says `public no`, and services.sh refuses a local provider that says `public yes`. The guard code of the public slot is unchanged.
