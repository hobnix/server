# dashboard

The capability that shows the services on a start page. A dashboard is a VARIANT: a script `scripts/providers/dashboard/<variant>.sh`
with `info` and `sync`. The runtime setting `dashboard` names it and switches the capability on; `hs recipe homepage` sets it.

- **What gets a tile.** A service (`/var/lib/hs/services.d/<name>.toml`) with `want.dashboard = true`. Its `title`, `group` (Administration,
  Apps, Monitoring, Games, Other, Public, or a group of its own), `description` and `icon` are the tile; the link is the public host when the
  service is published on a public proxy (a route that is `ok` in `hs services plan`), a host of a private proxy, else address and port.
  A service whose container is not running has no tile.
- **Icons.** `icon` is what Homepage understands: a brand name from its icon library (dashboard-icons: `jellyfin`, `immich`, `seerr`, `grafana`,
  `uptime-kuma` ...: the real logo), `mdi-<name>` for a generic Material Design icon, `si-<name>` for Simple Icons. The recipes that declare a
  service use the brand name; the `known()` table of homepage.sh (containers without a service) still uses `mdi-` icons. It is not the favicon
  of the page. To change one: `hs services declare <name> --container <ct> --port <n> --icon <name>`, then `hs services apply`.
- **Recipes declare their services** (`declare_service` in scripts/recipes/_lib.sh, in every recipe with a web page of its own; tests/recipes-declare.sh
  keeps it that way): they ask "show it on the dashboard?" (default yes) and "put it on the reverse proxy?" (default no) once, like the other preferences,
  and never make a service public. The tile of a container that has a service comes from the service; the table `known()` in
  recipes/homepage.sh stays as the fallback for the containers that do not, and shrinks as recipes declare theirs.
- **homepage** (the first variant): `sync` runs `recipes/homepage.sh --refresh` (only the links, no set-up, no questions); `hs services apply`
  calls it at its end when a service wants a tile, and `hs recipe homepage` writes the tiles with the rest of the links.

## Rules for working on it

Moved from CLAUDE.md (step 8 of docs/PLAN-modular-core.md); these are the rules for working on this part.

**Dashboard** (4d): the capability `dashboard` (runtime setting `dashboard`, set by `hs recipe homepage`; variant = scripts/providers/dashboard/<variant>.sh with `info|sync`): services with `want.dashboard` get a tile (`hs services tiles` for people, `hs sys services tiles` plain; link = public host if published, else address:port; an empty description is `-`), `recipes/homepage.sh --refresh` rewrites only the links and `hs services apply` calls it; the `known()` table in homepage.sh stays the fallback for containers without a service.
