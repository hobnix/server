# shellcheck shell=bash
# Steps shared by the recipes around films and series (radarr, sonarr, lidarr, bazarr, sabnzbd, seerr); sourced after _lib.sh,
# not run. Expects $scripts, $state, $ct and, for media_storage, $share.

# The share "media" read-write at /media, with a user of this container mapped 1:1 to the share's
# owner (the files stay adminuser's on disk, so Samba and Jellyfin see no change). Sets $ids (uid:gid).
# Radarr, Sonarr and SABnzbd must see the share at the SAME path: a download is imported by a
# hard link (no copy, no extra space), which only works inside one share and one filesystem.
media_storage() {   # media_storage <user inside the container>
  local user=$1
  if ${RUNS_DOCKER:-false}; then media_storage_docker; return; fi
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
  media_link_check "$ct" "$user"
}

# A download moves into the library by a hard link: try one with a real file, as the user, in the container <ct>
media_link_check() {   # media_link_check <container> <user>
  local c=$1 user=$2
  if incus exec "$c" -- su -s /bin/sh "$user" -c '
      set -e
      echo test > /media/downloads/usenet/complete/.hs-link-test
      ln /media/downloads/usenet/complete/.hs-link-test /media/movies/.hs-link-test
      [ "$(stat -c %i /media/downloads/usenet/complete/.hs-link-test)" = "$(stat -c %i /media/movies/.hs-link-test)" ]
      rm -f /media/downloads/usenet/complete/.hs-link-test /media/movies/.hs-link-test' </dev/null 2>/dev/null; then
    ok "Hard links work: a download moves into the library without a copy"
  else
    incus exec "$c" -- su -s /bin/sh "$user" -c 'rm -f /media/downloads/usenet/complete/.hs-link-test /media/movies/.hs-link-test' </dev/null 2>/dev/null || true
    warn "Hard links do not work on this storage. Imports will copy every file (twice the space until the download is deleted)."
  fi
}

# The same for a child of the container docker: one mapped user `media` (the idmap allows one per container) for every media app;
# the share comes in through `hs sys docker mount`, the one route the lock allows. Sets $ids; the compose file runs the app as it.
media_storage_docker() {
  local user=media others cmd
  step "User for the files"
  incus exec docker -- sh -c "id $user >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin $user" </dev/null
  ids=$(incus exec docker -- sh -c "echo \"\$(id -u $user):\$(id -g $user)\"" </dev/null)
  ok "$(t "User '%s' (%s)" "$user" "$ids")"
  step "Storage for films and downloads"
  if [ -n "${RECIPE_SKIP_STORAGE:-}" ]; then
    note "skipped (RECIPE_SKIP_STORAGE): the files stay inside the container"
    incus exec docker -- sh -c "mkdir -p /media; chown $user: /media" </dev/null
  elif [ "$(incus query "/1.0/instances/docker" | jq -r '[.expanded_devices[] | select(.path == "/media")] | length')" != 0 ]; then
    ok "/media is mounted already"
  else
    # the mount changes the user mapping of the container docker: it restarts, and everything in it with it. Do that on its own only
    # when nothing else runs there (the manager excepted); otherwise the owner decides (a web job has no terminal to ask).
    . "$scripts/lib/docker-apps.sh"
    cmd="hs sys docker mount $share /media --as $ids"
    others=$(docker_others_running "${app:-}") ||
      fail_fix "$(t "Could not read what runs in Docker, so the share is not mounted (the mount restarts everything in it).")" "$cmd"
    if [ -n "$others" ]; then
      others=${others//$'
'/, }
      warn "$(t "Mounting the share changes the user mapping: the container docker restarts, and with it everything in it (running now: %s)." "$others")"
      fail_fix "$(t "The share '%s' is not mounted at /media yet. Mount it yourself, then run this recipe again." "$share")" "$cmd"
    fi
    warn "$(t 'Mounting the share changes the user mapping: the container docker restarts, and with it every app in it.')"
    spin "$(t "Mounting the share '%s' at /media (read and write)" "$share")" bash "$scripts/docker.sh" mount "$share" /media --as "$ids" --yes
  fi
  spin "Waiting for the container" bash -c "$wait_address" _ docker "" 30
  incus exec docker -- su -s /bin/sh "$user" -c 'mkdir -p /media/movies /media/series /media/music /media/downloads/usenet/complete && touch /media/.hs-write-test && rm /media/.hs-write-test' </dev/null 2>/dev/null ||
    fail "$(t "'%s' can't write to /media. Look at the storage of '%s' in: hs ct list" "$user" docker)"
  media_link_check docker "$user"
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
  # a child of docker shares the descriptor of the container docker: only its own entry, named after the app, is replaced
  if ${RUNS_DOCKER:-false}; then backup_with_dump "${app:-media}" "$1"; return; fi
  [ -z "$1" ] || rm -f "$state/backup-dump/$ct" 2>/dev/null || true
  backup_with_dump media "$1"
}

# The Matrix hook as a notification channel of the server (provider scripts/notify/matrix.sh): the helpers next to the film apps no longer
# post to it, their events become messages through `hs notify` (scripts/event-notify.sh). Written when `hs recipe matrix-hook` has run; an
# existing channel keeps what the owner set (enabled, minimum priority ...) and only gets the new address. Sets nothing; $hook_ok is "yes"
# when the channel exists.
media_matrix_channel() {
  local sec ip_s port room hook="" hookconf=$state/recipe-synapse.conf conf
  hook_ok=no
  if [ -s "$state/matrix-hook" ]; then      # a closed vault leaves a dangling link: no hook until it is open
    sec=$(awk '$1 == "secret:" { print $2; exit }' "$state/matrix-hook" 2>/dev/null || true)
    ip_s=$(address "${HS_SYNAPSE:-synapse}" 2>/dev/null || true)
    port=$(sed -n 's/^HOOK_PORT=//p' "$hookconf" 2>/dev/null | tail -n1 || true)
    room=$(sed -n 's/^HOOK_ROOM=//p' "$hookconf" 2>/dev/null | tail -n1 || true)
    [ -z "$sec" ] || [ -z "$ip_s" ] || hook="http://$ip_s:${port:-8090}/hook/$sec/${room:-media}"
  fi
  if [ -z "$hook" ]; then [ -e "$(chan_dir)/matrix.conf" ] && hook_ok=yes; return 0; fi
  if conf=$(chan_conf matrix 2>/dev/null) && [ -n "$conf" ]; then
    printf '%s\n' "$conf" | grep -v '^url=' | { cat; printf 'url=%s\n' "$hook"; } | chan_write matrix
  else
    printf 'provider=matrix\nenabled=yes\nminprio=min\nquiet=respect\ncategories=alarm,status\nurl=%s\n' "$hook" | chan_write matrix
  fi
  hook_ok=yes
}

# What the helpers next to the film apps (hs-media-notify.py: the dedupe script, SABnzbd's notification script) need to know: the
# spool folder they drop their events in (the server turns them into messages: scripts/event-notify.sh and scripts/lib/notify-rules.tsv;
# the helper sends nothing and keeps no address) and, with $lookup, the Radarr/Sonarr address and keys. Written as JSON into
# <folder in the container>/hs-media-notify.json. Run again by the matrix-hook recipe, so a hook installed later reaches the channels.
media_notify_conf() {   # media_notify_conf <container> <folder inside it> [lookup]: lookup adds the Radarr/Sonarr address and keys
  local c=$1 dir=$2 lookup=${3:-} extra="" app a where aip akey tmp hook_ok
  . "$scripts/lib/channels.sh"
  media_ntfy      # (the film apps keep their own topic; the helpers do not use it any more)
  media_matrix_channel
  # Radarr and Sonarr each in a container of their own (recipes radarr, sonarr); an install of the older recipe arr
  # (both in the container arr) is asked when the new one is not there
  if [ -n "$lookup" ]; then
    for app in radarr:7878 sonarr:8989; do
      a=${app%%:*}
      for where in "$a:/opt/$a/config/config.xml" "arr:/opt/arr/$a/config.xml" "docker:/opt/apps/$a/config/config.xml" "docker:/shares/apps/recipes/$a/config/config.xml"; do
        aip=$(address "${where%%:*}" 2>/dev/null) && [ -n "$aip" ] || continue
        akey=$(incus exec "${where%%:*}" -- sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' "${where#*:}" </dev/null 2>/dev/null | head -n1 || true)
        [ -n "$akey" ] || continue
        extra="$extra, \"$a\": {\"url\": \"http://$aip:${app#*:}\", \"key\": \"$akey\"}"
        break
      done
    done
  fi
  tmp=$(mktemp)
  printf '{"spool": "/media/.hs-events"%s}\n' "$extra" > "$tmp"
  incus exec "$c" -- mkdir -p "$dir" </dev/null
  incus file push -q --mode "$([ -n "$lookup" ] && echo 0640 || echo 0644)" "$tmp" "$c$dir/hs-media-notify.json" && rm -f "$tmp"
  if [ "$hook_ok" = yes ]; then ok "$(t "Events from the helpers become messages through the notification channels, also in Matrix (%s)" "$c")"
  else note "$(t "Events from the helpers become messages through the notification channels (no Matrix hook yet: hs recipe matrix-hook, then run this recipe again)")"; fi
}
