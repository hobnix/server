#!/usr/bin/env bash
# media_notify_conf ... lookup (scripts/recipes/_media.sh): the Radarr and Sonarr address and API key for SABnzbd's cards, read from the
# containers radarr and sonarr (recipes of their own), else from the container arr of the older recipe. A fake incus serves the
# containers from a folder ($FAKE_FS/<container>/<path>); no root, no server.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
have jq || { skip "the lookup needs jq"; finish; exit 0; }
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
FAKE_FS=$WORK/fs; STATE=$WORK/state
mkdir -p "$WORK/bin" "$STATE"
export FAKE_FS
# FAKE_CTS="radarr=10.0.0.5 arr=10.0.0.9": the containers that exist, with their address
cat > "$WORK/bin/incus" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  query)
    n=${2#/1.0/instances/}; n=${n%%\?*}
    for c in ${FAKE_CTS:-}; do
      [ "${c%%=*}" = "$n" ] && { printf '{"state":{"network":{"eth0":{"addresses":[{"family":"inet","address":"%s"}]}}}}\n' "${c#*=}"; exit 0; }
    done
    echo "Error: Instance not found" >&2; exit 1 ;;
  exec)
    c=$2; shift 3
    if [ "$1" = sed ]; then f=${*: -1}; set -- "${@:1:$#-1}"; exec "$@" "$FAKE_FS/$c$f"; fi
    exit 0 ;;
  file)
    dest=${*: -1}; src=${*: -2:1}; mkdir -p "$(dirname "$FAKE_FS/$dest")"; cp "$src" "$FAKE_FS/$dest" ;;
esac
FAKE
chmod +x "$WORK/bin/incus"
export PATH="$WORK/bin:$PATH"
key() { mkdir -p "$(dirname "$FAKE_FS/$1")"; printf '<Config>\n  <ApiKey>%s</ApiKey>\n</Config>\n' "$2" > "$FAKE_FS/$1"; }
conf() {   # conf [lookup]: runs media_notify_conf for the container sabnzbd, prints what it wrote
  rm -rf "$FAKE_FS/sabnzbd"
  bash -c '
    set -euo pipefail
    scripts=$1; state=$2; ct=sabnzbd
    . "$scripts/recipes/_lib.sh"
    . "$scripts/recipes/_media.sh"
    media_notify_conf sabnzbd /opt/sabnzbd/config/scripts "$3"' _ "$SCRIPTS" "$STATE" "${1:-}" >/dev/null 2>&1
  cat "$FAKE_FS/sabnzbd/opt/sabnzbd/config/scripts/hs-media-notify.json"
}
pick() { jq -r "$1" <<<"$2"; }

echo "-- the recipes radarr and sonarr"
key radarr/opt/radarr/config/config.xml R-NEW
key sonarr/opt/sonarr/config/config.xml S-NEW
out=$(FAKE_CTS="radarr=10.0.0.5 sonarr=10.0.0.6" conf lookup)
check_eq "Radarr from its own container" "http://10.0.0.5:7878 R-NEW" "$(pick '"\(.radarr.url) \(.radarr.key)"' "$out")"
check_eq "Sonarr from its own container" "http://10.0.0.6:8989 S-NEW" "$(pick '"\(.sonarr.url) \(.sonarr.key)"' "$out")"
check_out "the push topic is still there" "^https://.*/hs-media-" pick .ntfy "$out"

echo "-- the older recipe arr"
key arr/opt/arr/radarr/config.xml R-OLD
key arr/opt/arr/sonarr/config.xml S-OLD
out=$(FAKE_CTS="arr=10.0.0.9" conf lookup)
check_eq "Radarr from the container arr" "http://10.0.0.9:7878 R-OLD" "$(pick '"\(.radarr.url) \(.radarr.key)"' "$out")"
check_eq "Sonarr from the container arr" "http://10.0.0.9:8989 S-OLD" "$(pick '"\(.sonarr.url) \(.sonarr.key)"' "$out")"
out=$(FAKE_CTS="radarr=10.0.0.5 sonarr=10.0.0.6 arr=10.0.0.9" conf lookup)
check_eq "both there: the new containers win" "R-NEW S-NEW" "$(pick '"\(.radarr.key) \(.sonarr.key)"' "$out")"
rm "$FAKE_FS/sonarr/opt/sonarr/config/config.xml"
out=$(FAKE_CTS="radarr=10.0.0.5 sonarr=10.0.0.6 arr=10.0.0.9" conf lookup)
check_eq "a new container without a key yet: the old one answers" "http://10.0.0.9:8989 S-OLD" "$(pick '"\(.sonarr.url) \(.sonarr.key)"' "$out")"

echo "-- nothing to find, or not asked"
out=$(FAKE_CTS="" conf lookup)
check_eq "no container: no address, no key" "null null" "$(pick '"\(.radarr) \(.sonarr)"' "$out")"
out=$(FAKE_CTS="radarr=10.0.0.5" conf)
check_eq "without lookup: no keys in the file" "null" "$(pick .radarr "$out")"
finish
