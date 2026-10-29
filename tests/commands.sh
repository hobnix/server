#!/usr/bin/env bash
# Registry, dispatcher and completion (scripts/lib/registry.tsv, scripts/lib/hs.sh). No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
HS="bash $SCRIPTS/lib/hs.sh"
REG=$SCRIPTS/lib/registry.tsv
export HS_LANG=en HS_COMPLETE_DIR=$WORK/complete
# the role "homeserver" implies these; without the file nothing is on and their commands are left out of `hs help`
export HS_CAPABILITIES_FILE=$WORK/capabilities
printf 'storage
incus
samba
backup
' > "$HS_CAPABILITIES_FILE"

echo "-- registry"
missing=""
for s in "$SCRIPTS"/*.sh; do
  b=$(basename "$s")
  grep -q "	$b	" "$REG" "$ROOT"/capabilities/*/commands.tsv || missing="$missing $b"   # a script is a row of the core or of an extension package
done
check_eq "every script has a row" "" "$missing"
bad=""
while IFS=$'\t' read -r kind path script args _; do
  case "$kind" in user|sys) ;; *) bad="$bad kind:$path" ;; esac
  if [ "$script" != "-" ] && [ ! -f "$SCRIPTS/$script" ]; then bad="$bad nofile:$script"; fi
  [ -n "$args" ] || bad="$bad noargs:$path"
done < <(grep -v '^#' "$REG")
check_eq "rows are well formed" "" "$bad"
nohelp=""
while IFS=$'\t' read -r kind path script _ hen _; do
  [ "$kind" = user ] || continue
  grep -q '^# help: ' "$SCRIPTS/$script" || [ "$hen" != "-" ] || nohelp="$nohelp $path"
done < <(grep -v '^#' "$REG")
check_eq "user commands have a help text" "" "$nohelp"

echo "-- help"
check_out "help lists the commands" "^  backup " $HS help
out=$($HS help)
if grep -q "sys registry" <<<"$out"; then fail "help hides system commands"; else pass "help hides system commands"; fi
: > "$HS_CAPABILITIES_FILE"   # an edge or minimal node: no storage, incus, samba, backup
out=$($HS help)
for w in backup pool disk share ct recipe; do
  if grep -q "^  $w " <<<"$out"; then fail "edge: hs help leaves out $w"; else pass "edge: hs help leaves out $w"; fi
done
check_out "edge: hs help --all still lists backup" "^  backup " $HS help --all
check_out "edge: core commands stay (config)" "^  config " $HS help
printf 'storage
incus
samba
backup
' > "$HS_CAPABILITIES_FILE"
check_out "help --all lists them" "sys backup state" $HS help --all
check_out "German help" "Befehle:" env HS_LANG=de $HS help
check_out "unknown command fails" "unknown command" $HS nonsense

echo "-- help for one command (the terminal's version of the docs site)"
check_out "words that are all command words pick one command" "^hs share <share> rename" $HS help share rename
check_eq "and only that one" "1" "$($HS help share rename | grep -c '^hs ')"
check_out "a value in the middle works" "^hs share <share> perm" $HS help share docs
check_out "a group lists its commands" "^hs ct <ct> start" $HS help ct
check_out "the explanation of the script follows" "Only on the ZFS layout" $HS help share snapshot
check_out "German text" "Freigabe umbenennen" env HS_LANG=de $HS help share rename
check_out "an old name is unknown now" "No such command: hs create-share" $HS help create-share
check_out "an unknown command says so" "No such command: hs nothing" $HS help nothing
check_eq "and fails" "1" "$($HS help nothing >/dev/null 2>&1; echo $?)"

echo "-- dispatch"
fake=$WORK/fake; mkdir -p "$fake/lib"
cp -r "$SCRIPTS"/lib/job.sh "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/i18n "$fake/lib/"
printf 'echo "args:$*"\n' > "$fake/x.sh"
printf '# kind\n# comment\nuser\tpool bulk add\tx.sh\t-\tadd\t-\t-\nuser\tslow thing\tx.sh\tgo\tslow\t-\tlong\nsys\tsys pool info\tx.sh\t--info\tinfo\t-\t-\nuser\tshare <share> rename\tx.sh\tren\trename\t-\t-\n' > "$fake/lib/registry.tsv"
F="bash $fake/lib/hs.sh"
check_eq "words, rest passed on" "args:--yes" "$(HS_CALLER=t $F pool bulk add --yes)"
check_eq "fixed args come first" "args:--info extra" "$(HS_CALLER=t $F sys pool info extra)"
check_eq "a value is handed to the script" "args:docs ren --force" "$(HS_CALLER=t $F share docs rename --force)"

echo "-- the REAL registry reaches the scripts with the right arguments (a wrong fixed-args field once sent "backup now" to backup.sh instead of "now")"
real=$WORK/real; mkdir -p "$real/lib"
cp -r "$SCRIPTS"/lib/job.sh "$SCRIPTS"/lib/hs.sh "$SCRIPTS"/lib/capability.sh "$SCRIPTS"/lib/registry-load.sh "$SCRIPTS"/lib/ui.sh "$SCRIPTS"/lib/i18n.sh "$SCRIPTS"/lib/setting.sh "$SCRIPTS"/lib/i18n "$SCRIPTS"/lib/registry.tsv "$real/lib/"
for s in backup unlock services; do printf 'echo "args:$*"
' > "$real/$s.sh"; done
R="bash $real/lib/hs.sh"
check_eq "hs backup now --dry-run" "args:now --dry-run" "$(HS_CALLER=t $R backup now --dry-run)"
check_eq "hs backup drill 3" "args:drill 3" "$(HS_CALLER=t $R backup drill 3)"
check_eq "hs backup drill ct" "args:drill ct" "$(HS_CALLER=t $R backup drill ct)"
check_eq "hs backup drill ct <name>" "args:drill ct arr" "$(HS_CALLER=t $R backup drill ct arr)"
check_eq "hs backup verify" "args:verify" "$(HS_CALLER=t $R backup verify)"
check_eq "hs backup prune" "args:prune" "$(HS_CALLER=t $R backup prune)"
check_eq "hs backup status" "args:status" "$(HS_CALLER=t $R backup status)"
check_eq "hs backup (bare)" "args:" "$(HS_CALLER=t $R backup)"
check_eq "hs unlock --status" "args:--status" "$(HS_CALLER=t $R unlock --status)"
check_eq "hs services key <service> keeps the service name" "args:key jellyfin" "$(HS_CALLER=t $R services key jellyfin)"
check_eq "hs services declare-known --dry-run" "args:declare-known --dry-run" "$(HS_CALLER=t $R services declare-known --dry-run)"

echo "-- system command warning"
check_out "a person is warned" "system command" env -u HS_CALLER HS_FORCE_TTY=1 $F sys pool info </dev/null
check_eq "the interface is not" "args:--info" "$(HS_CALLER=ui HS_FORCE_TTY=1 $F sys pool info)"
check_eq "a pipe is not" "args:--info" "$(env -u HS_CALLER $F sys pool info)"

echo "-- long commands"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "systemd-run $*" > "%s/job.log"\n' "$WORK" > "$WORK/bin/systemd-run"; chmod +x "$WORK/bin/systemd-run"
out=$(printf 'y\n' | PATH="$WORK/bin:$PATH" env -u HS_CALLER HS_FORCE_TTY=1 $F slow thing --x 2>&1)
check_out "asks before a long command" "take long" echo "$out"
check_out "and starts it as a job" "Started as job hs-job-slow-thing-" echo "$out"
check_out "with the caller marker and the failure hook" "HS_CALLER=job.*OnFailure|OnFailure.*HS_CALLER" cat "$WORK/job.log"
check_out "the job runs the script with its arguments" "go --x" cat "$WORK/job.log"
out=$(printf 'n\n' | PATH="$WORK/bin:$PATH" env -u HS_CALLER HS_FORCE_TTY=1 $F slow thing --x 2>&1)
check_out "no = waits here" "args:go --x" echo "$out"
check_eq "the interface is not asked" "args:go" "$(HS_CALLER=ui HS_FORCE_TTY=1 $F slow thing)"
check_out "--foreground skips the question" "args:go --x" env -u HS_CALLER HS_FORCE_TTY=1 $F slow thing --foreground --x
check_eq "backup now is long (and has its topic)" "long,nohelp,topic:backup,changes" "$(awk -F'\t' '$2 == "backup now" { print $7 }' "$REG" | sed 's/,cheat:[a-z]*//; s/,capability:[a-z]*//')"
# every current user row names its topic (the help page sorts by it)
bad=$(awk -F'\t' '$1 == "user" && $7 !~ /(^|,)topic:/ { print $2 }' "$REG" | paste -sd, -)
check_eq "every user row has a topic" "" "$bad"
bad=$(awk -F'\t' '$1 == "user" && $7 ~ /(^|,)topic:/ { n = split($7, a, ","); for (i = 1; i <= n; i++) if (a[i] ~ /^topic:/ && a[i] !~ /^topic:(instances|shares|users|disks|backup|jobs|system|security|network|docs)$/) print $2 " " a[i] }' "$REG" | paste -sd, -)
check_eq "topics are known names" "" "$bad"
# every current user row says what it does to the system (the help page can mark it)
bad=$(awk -F'\t' '$1 == "user" && $7 !~ /(^|,)(reads|changes)(,|$)/ { print $2 }' "$REG" | paste -sd, -)
check_eq "every user row says reads or changes" "" "$bad"

echo "-- extension packages (capabilities/<name>/commands.tsv, scripts/lib/registry-load.sh)"
. "$SCRIPTS/lib/registry-load.sh"
check_eq "no package row is refused" "" "$(HS_REGISTRY=$REG registry_refused | paste -sd, -)"
bad=""
for pkg in $(HS_REGISTRY=$REG ext_package_names); do
  while IFS=$'	' read -r kind path script args hen hde flags; do
    case "$script" in /*) [ -f "$script" ] || bad="$bad nofile:$script" ;; "@/"*) [ -f "$ROOT/capabilities/$pkg/${script#@/}" ] || bad="$bad nofile:$script" ;; *) [ -f "$SCRIPTS/$script" ] || bad="$bad nofile:$script" ;; esac
    [ -n "$args" ] || bad="$bad noargs:$path"
    if [ "$kind" = user ]; then
      [ "$hen" != "-" ] || bad="$bad nohelp:$path"
      [ "$hde" != "-" ] || bad="$bad nohelp.de:$path"
      case ",$flags," in *,topic:*) ;; *) bad="$bad notopic:$path" ;; esac
      case ",$flags," in *,reads,*|*,changes,*) ;; *) bad="$bad noreads:$path" ;; esac
    fi
  done < <(HS_REGISTRY=$REG _ext_filter "$pkg" "$ROOT/capabilities/$pkg" 0)
done
check_eq "package rows: scripts exist, help and help.de, topic, reads or changes" "" "$bad"
check_eq "the core registry has no row inside a package namespace" "" "$(awk -F'	' '$1 == "user" && $2 ~ /^ext [a-z]/ && $2 !~ /^ext (list|enable|disable|<package>)/ { print $2 } $1 == "sys" && $2 ~ /^sys ext [a-z]/ && $2 != "sys ext list" { print $2 }' "$REG" | paste -sd, -)"

echo "-- pool commands"
check_eq "hs pool <TAB> offers bulk and fast" "bulk fast" "$($HS sys complete pool | paste -sd' ')"
check_eq "hs pool bulk <TAB> offers the verbs" "add close convert open remove replace sync" "$($HS sys complete pool bulk | paste -sd' ')"
check_eq "no command that asks questions runs as a job" "" "$(awk -F'\t' '$1 == "user" && $2 ~ /^pool/ && $2 !~ /sync/ && $7 ~ /long/ { print $2 }' "$REG")"

echo "-- completion"
check_eq "first word has help and sys" "yes" "$($HS sys complete | grep -qx help && $HS sys complete | grep -qx sys && echo yes)"
if $HS sys complete | grep -qx registry; then fail "sys words stay hidden"; else pass "sys words stay hidden"; fi
check_eq "after sys" "yes" "$($HS sys complete sys | grep -qx backup && echo yes)"
check_eq "next words of a path" "add" "$(HS_REGISTRY=$fake/lib/registry.tsv $HS sys complete pool bulk)"
mkdir -p "$WORK/bulk/shares/docs" "$WORK/bulk/shares/media" "$WORK/bulk/sensitive/photos"
check_eq "values of <share>" "docs media photos" "$(HS_BULK=$WORK/bulk HS_REGISTRY=$fake/lib/registry.tsv $HS sys complete share | paste -sd' ')"

finish
