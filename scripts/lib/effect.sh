#!/usr/bin/env bash
# When a change takes effect (docs/adr/0002-system-state-vs-runtime-state.md rule 4). Every plan that changes configuration says it before the
# Apply button, with one of two fixed sentences: "takes effect at once" (runtime state) or "takes effect with hs rebuild" (declarative state).
# tests/apply-effect.sh checks that every plan and every CLI apply path does.
#
#   effect_now            -> "This takes effect at once; no rebuild is needed."
#   effect_rebuild        -> "This takes effect with hs rebuild. The last rebuild took about N min."   (or the placeholder before one was timed)
#   rebuild_took          -> just the timing sentence, with a leading space
# The timing is $HS_STATE_DIR/last-rebuild-seconds, written by rebuild.sh after a good build.

# the timing sentence: measured, or a conservative placeholder before the first measured rebuild on this server
rebuild_took() {
  local f=${HS_STATE_DIR:-/var/lib/hs}/last-rebuild-seconds sec
  sec=$(cat "$f" 2>/dev/null) || sec=""
  case $sec in
    ''|*[!0-9]*) printf ' A rebuild takes several minutes; none has been timed on this server yet.' ;;
    *) printf ' The last rebuild took about %s min.' "$(( (sec + 59) / 60 ))" ;;
  esac
}

effect_now() { printf 'This takes effect at once; no rebuild is needed.'; }
effect_rebuild() { printf 'This takes effect with hs rebuild.%s' "$(rebuild_took)"; }

# For the terminal (needs lib/ui.sh): effect_say now|rebuild prints the same sentences as notes, translated. Call it BEFORE the change is written.
effect_say() {
  local sec f=${HS_STATE_DIR:-/var/lib/hs}/last-rebuild-seconds
  case "$1" in
    now) note "$(t 'It takes effect at once; no rebuild is needed.')" ;;
    rebuild)
      note "$(t 'This takes effect with hs rebuild.')"
      sec=$(cat "$f" 2>/dev/null) || sec=""
      case $sec in
        ''|*[!0-9]*) note "$(t 'A rebuild takes several minutes; none has been timed on this server yet.')" ;;
        *) note "$(t 'The last rebuild took about %s min.' "$(( (sec + 59) / 60 ))")" ;;
      esac ;;
  esac
}
