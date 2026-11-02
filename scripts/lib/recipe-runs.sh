# shellcheck shell=bash
# Where a recipe may run (docs/PLAN-docker-instances.md, phase 6): the header line `# runs: lxc docker vm` of a recipe (missing = lxc).
# The owner PICKS the runtime in the recipe dialog; it is an ordinary question (`RUNS`, choice) built here, so `hs sys recipes asks` and
# `hs sys recipes plan|start` need no special case in the web interface. Test knobs: HS_STATE_DIR, HS_DOCKER_STATUS (a command that prints
# the key<TAB>value rows of `hs sys docker status`).
#   recipe_runs <file>                  the declared runtimes, one line, words
#   recipe_runs_default <file> <app>    the runtime the dialog starts with
#   recipe_runs_ask <file> <app>        (<app> = the instance name: --name, else the recipe) the `# ask:` line for RUNS (nothing unless more than one runtime is declared)
_runs_lib=$(cd "${BASH_SOURCE[0]%/*}" && pwd)

recipe_runs() {
  local w out=""
  for w in $(sed -n 's/^# runs: *//p' "$1" 2>/dev/null | head -n1 || true); do
    case "$w" in lxc|docker|vm) [[ " $out " == *" $w "* ]] || out+="${out:+ }$w" ;; esac
  done
  printf '%s
' "${out:-lxc}"
}

_runs_docker_on() {
  local rows
  if [ -n "${HS_DOCKER_STATUS:-}" ]; then rows=$($HS_DOCKER_STATUS 2>/dev/null || true)
  else rows=$(bash "$_runs_lib/../docker.sh" --status 2>/dev/null || true); fi
  printf '%s\n' "$rows" | grep -q '^state'$'\t''on$'
}

recipe_runs_default() {   # recipe_runs_default <file> <app>
  local file=$1 app=$2 declared saved conf w first=""
  declared=" $(recipe_runs "$file") "
  conf="${HS_STATE_DIR:-/var/lib/hs}/recipe-$app.conf"
  saved=$(sed -n 's/^RUNS=//p' "$conf" 2>/dev/null | tail -n1 || true)
  # an existing instance keeps its runtime
  if [[ "$declared" == *" lxc "* ]] && { [ "$saved" = lxc ] || incus info "$app" >/dev/null 2>&1; }; then echo lxc; return; fi
  if [[ "$declared" == *" docker "* ]] && [ "$saved" = docker ]; then echo docker; return; fi
  if [[ "$declared" == *" docker "* ]] && _runs_docker_on; then echo docker; return; fi
  for w in lxc docker; do
    if [[ "$declared" == *" $w "* ]]; then echo "$w"; return; fi
  done
  for w in $declared; do first=$w; break; done
  echo "${first:-lxc}"
}

recipe_runs_ask() {   # recipe_runs_ask <file> <app>
  local file=$1 app=$2 words def list w n=1 saved
  words=$(recipe_runs "$file")
  def=$(recipe_runs_default "$file" "$app")
  saved=$(sed -n 's/^RUNS=//p' "${HS_STATE_DIR:-/var/lib/hs}/recipe-$app.conf" 2>/dev/null | tail -n1 || true)
  list=$def
  # docker is offered only while Docker is on (or the app already runs there)
  for w in $words; do
    [ "$w" != "$def" ] || continue
    if [ "$w" = docker ] && [ "$saved" != docker ] && ! _runs_docker_on; then continue; fi
    list+=",$w"; n=$((n + 1))
  done
  [ "$n" -gt 1 ] || return 0
  printf 'RUNS|Where it runs (lxc: its own container, docker: inside the Docker container, vm: its own virtual machine)|choice:%s|%s||\n' "$list" "$def"
}
