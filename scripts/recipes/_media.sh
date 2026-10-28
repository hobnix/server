# shellcheck shell=bash
# Steps shared by the recipes around films and series (arr, sabnzbd, seerr); sourced after _lib.sh,
# not run. Expects $scripts, $state, $ct and, for media_storage, $share.

# The share "media" read-write at /media, with a user of this container mapped 1:1 to the share's
# owner (the files stay adminuser's on disk, so Samba and Jellyfin see no change). Sets $ids (uid:gid).
# Radarr, Sonarr and SABnzbd must see the share at the SAME path: a download is imported by a
# hard link (no copy, no extra space), which only works inside one share and one filesystem.
media_storage() {   # media_storage <user inside the container>
  local user=$1
  step "User for the files"
  incus exec "$ct" -- sh -c "id $user >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin $user" </dev/null
  ids=$(incus exec "$ct" -- sh -c "echo \"\$(id -u $user):\$(id -g $user)\"" </dev/null)
  ok "$(t "User '%s' (%s)" "$user" "$ids")"

  step "Storage for films and downloads"
  if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
    note "skipped (RECIPE_SKIP_STORAGE): the files stay inside the container"
    incus exec "$ct" -- sh -c "mkdir -p /media; chown $user: /media" </dev/null
  elif [ "$(incus query "/1.0/instances/$ct" | jq -r '[.expanded_devices[] | select(.path == "/media")] | length')" != 0 ]; then
    ok "/media is mounted already"
  else
    spin "$(t "Mounting the share '%s' at /media (read and write)" "$share")" \
      bash "$scripts/manage-ct.sh" "$ct" --add-storage shares "$share" /media --as "$ids"
  fi
  spin "Waiting for the container" bash -c "$wait_address" _ "$ct" "" 30      # the mount may have restarted it
  ip=$(address "$ct")
  incus exec "$ct" -- su -s /bin/sh "$user" -c 'mkdir -p /media/movies /media/series /media/music /media/downloads/usenet/complete && touch /media/.hs-write-test && rm /media/.hs-write-test' </dev/null 2>/dev/null ||
    fail "$(t "'%s' can't write to /media. Look at the storage of '%s' in: hs ct list" "$user" "$ct")"
  # A download moves into the library by a hard link: try one with a real file
  if incus exec "$ct" -- su -s /bin/sh "$user" -c '
      set -e
      echo test > /media/downloads/usenet/complete/.hs-link-test
      ln /media/downloads/usenet/complete/.hs-link-test /media/movies/.hs-link-test
      [ "$(stat -c %i /media/downloads/usenet/complete/.hs-link-test)" = "$(stat -c %i /media/movies/.hs-link-test)" ]
      rm -f /media/downloads/usenet/complete/.hs-link-test /media/movies/.hs-link-test' </dev/null 2>/dev/null; then
    ok "Hard links work: a download moves into the library without a copy"
  else
    incus exec "$ct" -- su -s /bin/sh "$user" -c 'rm -f /media/downloads/usenet/complete/.hs-link-test /media/movies/.hs-link-test' </dev/null 2>/dev/null || true
    warn "Hard links do not work on this storage. Imports will copy every file (twice the space until the download is deleted)."
  fi
}

# The push topic of the film apps (Radarr, Sonarr, Seerr). A topic of its own, on the same ntfy
# server as the alarms of this server (notifyUrl): the topic is the only secret of ntfy, and the
# apps keep it in their databases, so it must not be the one that carries "unlock needed".
# Sets $ntfy_server and $ntfy_topic; the topic is made once and kept in $state/media-ntfy.
media_ntfy() {
  local f=$state/media-ntfy url base
  if [ ! -s "$f" ]; then
    url=$(cat "$state/notify-url" 2>/dev/null || cat /etc/hs/notify-url 2>/dev/null || true)
    base=$(printf '%s' "$url" | sed -n 's|^\(https\{0,1\}://[^/]*\)/.*|\1|p')
    mkdir -p "$state" 2>/dev/null || true
    printf '%s hs-media-%s\n' "${base:-https://ntfy.sh}" "$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')" > "$f"
    chmod 600 "$f" 2>/dev/null || true
  fi
  read -r ntfy_server ntfy_topic < "$f"
}

# Include the container in the nightly backup and write the command that makes its databases safe to
# copy while the apps run (the file backup runs it inside the container right before).
media_backup() {   # media_backup <command inside the container, or "" for none>
  # these containers have exactly one dump command: it replaces the descriptor (older runs wrote a bare line, without a name)
  [ -z "$1" ] || rm -f "$state/backup-dump/$ct" 2>/dev/null || true
  backup_with_dump media "$1"
}

# The addresses the helpers next to the film apps (hs-media-notify.py: the dedupe script, SABnzbd's
# notification script) send to: the push topic of media_ntfy and, when `hs recipe matrix-hook` has run, the
# webhook address of the Matrix hook. Written as JSON into <folder in the container>/hs-media-notify.json.
# Run again by the matrix-hook recipe, so a hook installed later reaches containers that exist already.
media_notify_conf() {   # media_notify_conf <container> <folder inside it> [lookup]: lookup adds the Radarr/Sonarr address and keys
  local c=$1 dir=$2 lookup=${3:-} extra="" app port aip akey hookconf=$state/recipe-synapse.conf hook="" sec ip_s port room tmp
  media_ntfy
  if [ -s "$state/matrix-hook" ]; then      # a closed vault leaves a dangling link: no hook until it is open
    sec=$(awk '$1 == "secret:" { print $2; exit }' "$state/matrix-hook" 2>/dev/null || true)
    ip_s=$(address "${HS_SYNAPSE:-synapse}" 2>/dev/null || true)
    port=$(sed -n 's/^HOOK_PORT=//p' "$hookconf" 2>/dev/null | tail -n1 || true)
    room=$(sed -n 's/^HOOK_ROOM=//p' "$hookconf" 2>/dev/null | tail -n1 || true)
    [ -z "$sec" ] || [ -z "$ip_s" ] || hook="http://$ip_s:${port:-8090}/hook/$sec/${room:-media}"
  fi
  if [ -n "$lookup" ] && aip=$(address arr 2>/dev/null) && [ -n "$aip" ]; then
    for app in radarr:7878 sonarr:8989; do
      akey=$(incus exec arr -- sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' "/opt/arr/${app%%:*}/config.xml" </dev/null 2>/dev/null | head -n1 || true)
      [ -z "$akey" ] || extra="$extra, \"${app%%:*}\": {\"url\": \"http://$aip:${app#*:}\", \"key\": \"$akey\"}"
    done
  fi
  tmp=$(mktemp)
  printf '{"ntfy": "%s/%s"%s%s}\n' "$ntfy_server" "$ntfy_topic" "${hook:+, \"hook\": \"$hook\"}" "$extra" > "$tmp"
  incus exec "$c" -- mkdir -p "$dir" </dev/null
  incus file push -q --mode "$([ -n "$lookup" ] && echo 0640 || echo 0644)" "$tmp" "$c$dir/hs-media-notify.json" && rm -f "$tmp"
  if [ -n "$hook" ]; then ok "$(t "Messages from the helpers go to ntfy and to Matrix (%s)" "$c")"
  else note "$(t "Messages from the helpers go to ntfy only (no Matrix hook yet: hs recipe matrix-hook, then run this recipe again)")"; fi
}
