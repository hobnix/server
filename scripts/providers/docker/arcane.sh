# shellcheck shell=bash
# Variant "arcane" of the docker capability (capabilities/docker/NOTES.md): the web page that manages Docker, as a compose project in
# /opt/arcane. SOURCED by packages/docker/run.sh (and tests/docker-managers.sh), not run. A variant defines:
#   manager_title, manager_icon, manager_desc   the service (hs services, the dashboard tile)
#   manager_default_port                        the port of its web page on the container (the compose file publishes its own port on it)
#   manager_dir                                 where its compose project lives
#   manager_log_hint                            what to look at when it does not answer
#   manager_prepare   shell lines run INSIDE the container before the compose file is written (the directory, keys that are made once)
#   manager_compose <port> <url>   the compose file on stdout
#   manager_stop      shell lines run inside the container to stop it (containers go, the volume and the compose file stay)
#   manager_box       the lines of the closing text of the recipe
manager_title=Arcane
manager_icon=arcane
manager_desc="Docker stacks"
manager_default_port=80
manager_dir=/opt/arcane
manager_log_hint="docker logs --tail 30 arcane"

manager_prepare() {
  cat <<'SH'
dir=${ARCANE_DIR:-/opt/arcane}; projects=${PROJECTS_DIR:-/opt/projects}   # (the variables are for the tests)
mkdir -p "$dir" "$projects" && cd "$dir"
# A compose file this recipe did not write belongs to an older install (by hand, or an older recipe): keep it once. Its keys may be in it.
if [ -f docker-compose.yml ] && ! grep -q 'Written by "hs recipe docker"' docker-compose.yml && [ ! -e docker-compose.yml.before-recipe ]; then
  cp -p docker-compose.yml docker-compose.yml.before-recipe
fi
# The keys are made ONCE: with new ones Arcane cannot read what it stored (the login fails with a server error, then 401).
if [ ! -s .env ]; then
  # an older install has them in its compose file (ENCRYPTION_KEY=... or ENCRYPTION_KEY: ...): carry them over, never a ${placeholder}
  carry=$(cat docker-compose.yml.before-recipe docker-compose.yml 2>/dev/null |
    sed -nE 's/^[[:space:]]*-?[[:space:]]*(ENCRYPTION_KEY|JWT_SECRET)[[:space:]]*[=:][[:space:]]*"?([^"[:space:]$]+)"?[[:space:]]*$/\1=\2/p' | awk -F= '!seen[$1]++' || true)
  # the ENCRYPTION_KEY protects what Arcane stored: it must be carried over. The JWT_SECRET only signs logins: a new one just logs people out.
  if printf '%s\n' "$carry" | grep -q '^ENCRYPTION_KEY='; then
    printf '%s\n' "$carry" | grep -q '^JWT_SECRET=' || carry=$(printf '%s\nJWT_SECRET=%s' "$carry" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n")")
    ( umask 077; printf '%s\n' "$carry" > .env )
  elif command -v docker >/dev/null 2>&1 && docker volume ls -q 2>/dev/null | grep -qi arcane; then
    echo "Arcane has stored data here (a docker volume) but no ENCRYPTION_KEY could be found to carry over: new keys would lock you out of it. Restore the old compose file (from a snapshot: incus snapshot list) and run again, or, for a fresh Arcane, run 'docker compose down -v' in $dir first." >&2
    exit 1
  else
    ( umask 077; printf "ENCRYPTION_KEY=%s\nJWT_SECRET=%s\n" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n")" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n")" > .env )
  fi
fi
SH
}

manager_compose() {   # manager_compose <port> <url>
  cat <<YML
# Written by "hs recipe docker". Run it again after changes; edits here are overwritten.
services:
  arcane:
    image: ghcr.io/getarcaneapp/arcane:latest
    container_name: arcane
    restart: unless-stopped
    ports:
      - "$1:3552"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - arcane-data:/app/data
      - /opt/projects:/app/data/projects
    env_file: .env
    environment:
      - APP_URL=$2

volumes:
  arcane-data:
YML
}

manager_stop() { echo 'cd /opt/arcane && docker compose down'; }

manager_box() {
  say "First login:  user  arcane   password  arcane-admin  (Arcane asks for a new one right away)"
  say "Arcane itself never gets a Zoraxy rule."
}
