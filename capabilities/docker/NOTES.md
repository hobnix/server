# docker

The `docker` container (`hs recipe docker`, also `RECIPE_NAME=<name>` for more Docker hosts) with Docker inside and, as a VARIANT, the web page
that manages it: `arcane` (default; installs from before the question count as arcane), `portainer`, or `none` (Docker only).

- **The choice** is the recipe preference `MANAGER`, per container (`recipe-<ct>.conf`, `RECIPE_MANAGER=portainer`, `hs recipe docker --ask`).
  A variant is a file `scripts/providers/docker/<variant>.sh` that the recipe SOURCES: `manager_title|icon|desc|default_port|dir|log_hint`,
  `manager_prepare` (shell run in the container), `manager_compose <port> <url>` (the compose file), `manager_stop`, `manager_box`
  (see arcane.sh). tests/docker-managers.sh checks every variant defines them and publishes the recipe's port.
- **Switching** (`hs recipe docker --ask`, answer the other manager): the old manager's containers are stopped (`docker compose down`), its
  volume and compose file stay, so switching back works and your own apps keep running. Nothing is deleted.
- **The service**: the recipe declares `docker` (title, icon, port of the variant) as `never-public`, group Administration: a manager
  controls Docker and never gets a Zoraxy rule. Whatever a manager offers on the internet (Arcane's GitHub build webhook
  `/api/webhooks/trigger`, Portainer's own webhook paths) is a `public_paths` descriptor a person adds with `hs services`: it differs per
  manager, so it is not part of the variant.
- **arcane**: compose project in /opt/arcane (port 3552 published on the recipe's port, default 80), the keys in `.env` are made once
  (an older install's `ENCRYPTION_KEY` is carried over (a `JWT_SECRET` too, else a new one is made) from its compose file, which is kept once as `docker-compose.yml.before-recipe`;
  with stored data and no keys found the recipe stops: new keys would lock you out), projects in /opt/projects. **portainer**: Portainer CE (`portainer/portainer-ce:lts`) in /opt/portainer; HTTP is only served with its flag
  `--http-enabled` (port 9000, published on the recipe's port); it asks for the admin account within about 5 minutes of starting
  (`docker restart portainer` if it timed out); /opt/projects is mounted too, so compose files there stay reachable.

## Rules for working on it

Moved from CLAUDE.md (step 8 of docs/PLAN-modular-core.md); these are the rules for working on this part.

**The docker recipe has a manager variant** (4e): `MANAGER` arcane (default) | portainer | none, a recipe preference per container; a variant is a file scripts/providers/docker/<variant>.sh the recipe SOURCES (title, icon, port, compose file, stop; tests/docker-managers.sh); switching stops the old manager's containers and keeps its volume and compose file (capabilities/docker/NOTES.md).
