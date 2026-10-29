# dashboard

The capability that shows the services on a start page. A dashboard is a VARIANT: a script `scripts/providers/dashboard/<variant>.sh`
with `info` and `sync`. The runtime setting `dashboard` names it and switches the capability on. The only variant is `web`.

- **What gets a tile.** A service (`/var/lib/hs/services.d/<name>.toml`) with `want.dashboard = true`. Its `title`, `group` (Administration,
  Apps, Monitoring, Games, Other, or a group of its own), `description` and `icon` are the tile; the link is the public host when the
  service is published on a public proxy (a route that is `ok` in `hs services plan`), a host of a private proxy, else address and port.
  A service whose container is not running has no tile.
- **web** (the variant): the page `/dashboard` of the web interface (webUi). It reads the tiles itself from `GET /api/board`, so `sync` writes
  nothing. With a sign-in the Services page shows the same tiles as a card. Without one (the full-screen kiosk) the answer is given only while
  the runtime setting `dashboardOpen` is true, to a private client address and a Host header that names this server. What it reveals to everyone
  there: the titles, descriptions, links and state of every tile.
- **Icons.** `icon` is a name from the Phosphor map in web/src/dashboard/icons.js; an unknown name falls back to a monogram (first letter).
  To change one: `hs services declare <name> --container <ct> --port <n> --icon <name>`.
- **Recipes declare their services** (`declare_service` in scripts/recipes/_lib.sh, in every recipe with a web page of its own; tests/recipes-declare.sh
  keeps it that way): they ask "show it on the dashboard?" (default yes) and "put it on the reverse proxy?" (default no) once, like the other
  preferences, and never make a service public. Containers set up before their recipe declared a service: `hs services declare-known` (one release).
- The Homepage recipe was removed (2026-10-29); `hs update` sets `dashboard = web`, the old container stays until you remove it yourself.
- Live stats on tiles: step 3 of the dashboard-web work (not here yet).

## Rules for working on it

Moved from CLAUDE.md (step 8 of docs/PLAN-modular-core.md); these are the rules for working on this part.

**Dashboard** (4d): the capability `dashboard` (runtime setting `dashboard`, variant = scripts/providers/dashboard/<variant>.sh with `info|sync`; the only variant is `web`, read live from `/api/board`): services with `want.dashboard` get a tile (`hs services tiles` for people, `hs sys services tiles` plain; link = public host if published, else address:port; an empty description is `-`).
