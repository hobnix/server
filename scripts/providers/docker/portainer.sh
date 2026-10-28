# shellcheck shell=bash
# Variant "portainer" of the docker capability (capabilities/docker/NOTES.md): Portainer CE as a compose project in /opt/portainer.
# SOURCED by packages/docker/run.sh (and tests/docker-managers.sh); the functions and variables are described in arcane.sh.
# Portainer serves HTTPS on 9443 and, only with --http-enabled (a flag of its own, found in its sources), HTTP on 9000. The page is
# for the home network, behind nothing, so the plain HTTP port is published on the port the recipe asks for (default 80), the same
# address Arcane would have had.
manager_title=Portainer
manager_icon=portainer
manager_desc="Docker containers and stacks"
manager_default_port=80
manager_dir=/opt/portainer
manager_log_hint="docker logs --tail 30 portainer"

manager_prepare() {
  cat <<'SH'
mkdir -p /opt/portainer /opt/projects && cd /opt/portainer
SH
}

manager_compose() {   # manager_compose <port> <url>
  cat <<YML
# Written by "hs recipe docker". Run it again after changes; edits here are overwritten.
services:
  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    command: --http-enabled
    ports:
      - "$1:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer-data:/data
      - /opt/projects:/opt/projects

volumes:
  portainer-data:
YML
}

manager_stop() { echo 'cd /opt/portainer && docker compose down'; }

manager_box() {
  say "First visit: Portainer asks for the admin account right away. It waits only about 5 minutes after it starts;"
  say "if the page says it timed out: incus exec docker -- docker restart portainer, then open it again."
  say "Portainer itself never gets a Zoraxy rule."
}
