#!/usr/bin/env bash
# help: change the ISO library without asking anything: what would happen (plan), then do it as a background job (start)
# help.de: die ISO-Bibliothek ändern, ohne etwas zu fragen: was passieren würde (plan), dann als Hintergrundjob ausführen (start)
# args: plan|start add <file-or-url> [--name <name.iso>] (--checksum <sha256|sha512> | --no-checksum) | plan|start remove <name> [--confirm <name>]
# System command (hs sys iso plan|start): for the interface, timers and tests. It never asks and prints plain key<TAB>value lines like
# ct-change.sh. Issue #259 (epic #199).
#   add <file-or-url>   a local file (an absolute path) or an http(s) URL; it is copied or downloaded into the library folder (hs iso --dir), checked
#                       to be an ISO 9660 image and verified against the checksum before it appears in the list. The checksum is mandatory:
#                       --checksum <64 hex = SHA-256 | 128 hex = SHA-512> (an optional sha256: / sha512: prefix is accepted), or
#                       --no-checksum when there is none to compare: the job then prints the computed SHA-256 so it can be compared by hand
#                       and the image is listed as not checked. A mismatch deletes the file and fails the job with both checksums.
#   remove <name>       delete an image; refused while an instance has it attached. Red: the name must be typed (--confirm).
# plan: exit 0 = allowed, 1 = refused, 2 = something is still missing. Output, in this order:
#   status<TAB>ok|refused|needs
#   needs<TAB>checksum           (status needs: nothing else is printed)
#   reason<TAB><text>            (status refused)
#   heading|step|note|warn|danger|command<TAB><line>   (status ok)
#   confirm_name<TAB><name>      only when the plan has a danger line (remove)
#   long<TAB>yes|no
# start: the same checks, then add runs as a background job (status<TAB>started, unit<TAB><job unit>), remove answers status<TAB>done.
# The job is `iso-change.sh apply-add ...`: it reports steps and progress to its job record and stops cleanly when the record says cancelled
# (the partial file is removed then, also on `hs job stop`).
# Test knobs: HS_ISO_DIR, HS_CURL (stand-in for curl), HS_INCUS, HS_ISO_POLL (seconds between two progress checks).
set -euo pipefail
here=$(dirname "$0")
. "$here/lib/iso.sh"
curl_bin=${HS_CURL:-curl}
poll=${HS_ISO_POLL:-1}

# ── the job: copy or download, check, verify, publish ──
if [ "${1:-}" = apply-add ]; then
  shift
  . "$here/lib/job.sh"
  src="" name="" algo="" want="" nochecksum=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --src) src=$2; shift 2 ;; --name) name=$2; shift 2 ;; --algo) algo=$2; shift 2 ;; --expect) want=$2; shift 2 ;;
      --no-checksum) nochecksum=true; shift ;; *) echo "unknown option $1" >&2; exit 2 ;;
    esac
  done
  iso_valid_name "$name" || { echo "invalid image name" >&2; exit 2; }
  dir=$(iso_dir); dest=$dir/$name; part=$dest.part
  mkdir -p "$dir"
  child=""
  cleanup() { [ -z "$child" ] || kill "$child" 2>/dev/null || true; rm -f -- "${part:?}"; }
  trap 'cleanup; echo "cancelled: the partial file is removed" >&2; exit 143' TERM INT
  trap 'rc=$?; [ "$rc" -eq 0 ] || cleanup; exit "$rc"' EXIT

  total=0
  hs_job_step 1 3 "fetch"
  if [[ "$src" == http://* || "$src" == https://* ]]; then
    [[ "$src" != http://* ]] || echo "warning: plain HTTP: the download can be changed on the way. Compare the checksum."
    total=$("$curl_bin" -sIL --max-time 20 --proto '=http,https' -- "$src" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }') || total=0
    echo "download $src"
    "$curl_bin" -fsSL --proto '=http,https' --proto-redir '=http,https' --max-redirs 5 --connect-timeout 20 -o "$part" -- "$src" &
  else
    total=$(stat -c %s -- "$src" 2>/dev/null || echo 0)
    echo "copy $src"
    cp --reflink=auto -- "$src" "$part" &
  fi
  child=$!
  while kill -0 "$child" 2>/dev/null; do
    if hs_job_cancelled; then cleanup; echo "cancelled: the partial file is removed" >&2; exit 0; fi
    hs_job_progress "$(stat -c %s "$part" 2>/dev/null || echo 0)" "$total" bytes
    sleep "$poll"
  done
  if ! wait "$child"; then child=""; echo "failed: the file could not be fetched" >&2; exit 1; fi
  child=""

  hs_job_step 2 3 "check"
  # an ISO 9660 image has "CD001" at byte 32769
  if [ "$(dd if="$part" bs=1 skip=32769 count=5 2>/dev/null)" != CD001 ]; then
    echo "failed: this is not an ISO image (no ISO 9660 signature). The file is deleted." >&2; exit 1
  fi
  [ -n "$algo" ] || algo=sha256
  hs_job_step 3 3 "checksum"
  got=$("${algo}sum" "$part" | awk '{ print $1 }')
  verified=no
  if ! $nochecksum; then
    if [ "$got" != "$want" ]; then
      printf 'failed: the checksum does not match. The file is deleted.\n  expected (%s): %s\n  computed (%s): %s\n' "$algo" "$want" "$algo" "$got" >&2
      exit 1
    fi
    verified=yes
    echo "checksum ok ($algo): $got"
  else
    echo "no checksum was given. The computed $algo is: $got"
    echo "Compare it with the one on the download page before you install from this image."
  fi
  mv -f -- "$part" "$dest"
  chmod 644 "$dest"
  printf 'algo=%s\nhash=%s\nverified=%s\nsource=%s\nadded=%s\n' "$algo" "$got" "$verified" "$src" "$(date +%F)" > "$dest.meta"
  echo "added $name"
  exit 0
fi

refuse() { printf 'status\trefused\nreason\t%s\n' "$1"; exit 1; }

verb=${1:-}; action=${2:-}
case "$verb" in plan|start) ;; *) echo "usage: iso-change.sh plan|start add <file-or-url> [--name <n>] (--checksum <hex> | --no-checksum) | remove <name> [--confirm <n>]" >&2; exit 1 ;; esac
case "$action" in add|remove) ;; *) refuse "unknown action (add or remove)" ;; esac
[ $# -ge 3 ] || refuse "$([ "$action" = add ] && echo 'a file or URL is needed' || echo 'a name is needed')"
arg=$3
shift 3
name="" checksum="" nochecksum=false confirm=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name=${2:-}; shift 2 || refuse "--name needs a value" ;;
    --checksum) checksum=${2:-}; shift 2 || refuse "--checksum needs a value" ;;
    --no-checksum) nochecksum=true; shift ;;
    --confirm) confirm=${2:-}; shift 2 || refuse "--confirm needs a value" ;;
    *) refuse "unknown option $1" ;;
  esac
done
dir=$(iso_dir)

if [ "$action" = remove ]; then
  iso_valid_name "$arg" || refuse "invalid image name '$arg'"
  [ -f "$dir/$arg" ] || refuse "There is no image called '$arg' in the library."
  used=$(iso_used_by "$arg")
  [ "$used" = - ] || refuse "'$arg' is attached to $used. Detach it there first."
  if [ "$verb" = start ]; then
    [ "$confirm" = "$arg" ] || refuse "type the name to confirm: $arg"
    rm -f -- "${dir:?}/${arg:?}" "${dir:?}/${arg:?}.meta"
    printf 'status\tdone\n'
    exit 0
  fi
  printf 'status\tok\nheading\tremove %s from the ISO library\nstep\tdelete the image file and its checksum record\n' "$arg"
  printf 'danger\t%s is deleted for good. Download it again to get it back.\n' "$arg"
  printf 'confirm_name\t%s\ncommand\ths iso remove %s\nlong\tno\n' "$arg" "$arg"
  exit 0
fi

# ── add: the checks ──
[ -z "$confirm" ] || refuse "--confirm belongs to remove"
case "$arg" in
  http://*|https://*)
    [ ${#arg} -le 1000 ] || refuse "the URL is too long"
    [[ "$arg" =~ ^https?://[A-Za-z0-9._~-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+=:@,\;\&?-]*)?$ ]] || refuse "invalid URL (http or https, no user name or password in it)"
    host=${arg#*://}; host=${host%%[/:?]*}
    # curl also reads 2130706433, 0x7f.1 and 0177.0.0.1 as 127.0.0.1: a host of digits and dots must be a plain a.b.c.d, a hex part is refused
    if [[ "$host" =~ ^[0-9.]+$ ]] && ! [[ "$host" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]]; then refuse "write an IP address as a.b.c.d (or use a name): $host"; fi
    [[ ! "$host" =~ (^|\.)0[xX] ]] || refuse "write an IP address as a.b.c.d (or use a name): $host"
    host=${host%.}
    case "$host" in localhost|127.*|0.*|169.254.*|*.localhost) refuse "this server does not download from itself ($host)" ;; esac
    kind=url ;;
  /*)
    [[ "$arg" != *..* ]] || refuse "no \"..\" in a path"
    [[ "$arg" =~ ^/[A-Za-z0-9._/@+\ ~-]*$ ]] || refuse "invalid path"
    [ -f "$arg" ] || refuse "There is no file '$arg'."
    [ -r "$arg" ] || refuse "The file '$arg' cannot be read."
    [[ "$arg" != "$dir"/* ]] || refuse "That file is in the library already."
    kind=path ;;
  *) refuse "give an absolute path of a file on this server, or an http(s) URL" ;;
esac
if [ -z "$name" ]; then
  name=${arg%%[?#]*}; name=${name##*/}
fi
iso_valid_name "$name" || refuse "'$name' is not a usable image name: letters, digits, . _ - and it ends in .iso (use --name)"
[ ! -e "$dir/$name" ] || refuse "There is an image called '$name' in the library already. Remove it first or use --name."

algo="" want=""
if [ -n "$checksum" ]; then
  $nochecksum && refuse "give --checksum or --no-checksum, not both"
  c=${checksum,,}
  case "$c" in sha256:*) c=${c#sha256:}; pre=sha256 ;; sha512:*) c=${c#sha512:}; pre=sha512 ;; *) pre="" ;; esac
  [[ "$c" =~ ^[0-9a-f]+$ ]] || refuse "the checksum is hexadecimal text"
  case ${#c} in 64) algo=sha256 ;; 128) algo=sha512 ;; *) refuse "the checksum has ${#c} characters: SHA-256 has 64, SHA-512 has 128" ;; esac
  [ -z "$pre" ] || [ "$pre" = "$algo" ] || refuse "the prefix $pre does not fit a checksum of ${#c} characters"
  want=$c
elif ! $nochecksum; then
  printf 'status\tneeds\nneeds\tchecksum\n'; exit 2
fi

size=0
if [ "$kind" = path ]; then size=$(stat -c %s -- "$arg")
else size=$("$curl_bin" -sIL --max-time 8 --proto '=http,https' -- "$arg" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }') || size=0; fi
mkdir -p "$dir" 2>/dev/null || true
free=$(df -PB1 "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }') || free=""
if [ -n "$free" ] && [ "$size" -gt 0 ] && [ "$size" -gt "$free" ]; then
  refuse "Not enough room in $dir: the image needs $(numfmt --to=iec "$size" 2>/dev/null || echo "$size") and $(numfmt --to=iec "$free" 2>/dev/null || echo "$free") are free. Change the folder with the setting isoDir."
fi
human=""; [ "$size" -le 0 ] || human=" ($(numfmt --to=iec "$size" 2>/dev/null || echo "$size"))"

jargs=(--src "$arg" --name "$name")
if [ -n "$algo" ]; then jargs+=(--algo "$algo" --expect "$want"); else jargs+=(--no-checksum); fi

if [ "$verb" = start ]; then
  . "$here/lib/job.sh"
  unit=$(hs_job "iso-add-$name" "hs iso add $name" -- bash "$(cd "$here" && pwd)/iso-change.sh" apply-add "${jargs[@]}") || refuse "the job could not be started"
  printf 'status\tstarted\nunit\t%s\n' "$unit"
  exit 0
fi

printf 'status\tok\nheading\tadd %s to the ISO library\n' "$name"
if [ "$kind" = url ]; then printf 'step\tdownload %s%s into %s\n' "$arg" "$human" "$dir"; else printf 'step\tcopy %s%s into %s\n' "$arg" "$human" "$dir"; fi
printf 'step\tcheck that it is an ISO image\n'
if [ -n "$algo" ]; then printf 'step\tverify the %s checksum; a wrong one deletes the file and fails the job\n' "$algo"
else printf 'step\tcompute the SHA-256 and show it\nwarn\tNo checksum was given: nothing is verified. Compare the computed SHA-256 with the one on the download page before you install from it.\n'; fi
[[ "$arg" != http://* ]] || printf 'warn\tThis is a plain HTTP address: the download can be changed on the way. Prefer HTTPS and check the checksum.\n'
printf 'note\tThe download is a background job; stopping it removes the partial file.\n'
printf 'command\ths iso add %s%s\nlong\tyes\n' "$arg" "$([ -n "$algo" ] && echo " --checksum $want" || echo " --no-checksum")"
