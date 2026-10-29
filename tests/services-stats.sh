#!/usr/bin/env bash
# Live dashboard values: hs services stats (the fetcher) and hs services key. A fake incus and a fake curl that records its argv and its
# stdin; the Jellyfin example uses a made-up key (no real one). The key must be on curl's STDIN and in no argument.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export MSYS2_ARG_CONV_EXCL='/api;path=;domain=;vdir='
export HS_STATE_DIR=$WORK/state HS_SETTINGS_DIR=$WORK/state/settings HS_SERVICES_DIR=$WORK/services.d HS_ETC_DIR=$WORK/etc
export HS_VAULT_DIR=$WORK/vault HS_PYTHON=python3
BIN=$WORK/bin; mkdir -p "$BIN" "$HS_SETTINGS_DIR" "$HS_ETC_DIR" "$HS_SERVICES_DIR"
S="bash $SCRIPTS/services.sh"
T=$'\t'
KEY=Jf8k2Qm9Zx3Lp7Rt

cat > "$WORK/instances.json" <<'EOF'
[
 {"name":"jellyfin","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.50"}]}}}},
 {"name":"plain","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.10.95.51"}]}}}}
]
EOF
printf '#!/usr/bin/env bash\ncat "%s/instances.json"\n' "$WORK" > "$BIN/incus"; chmod +x "$BIN/incus"
export HS_INCUS=$BIN/incus

# the fake curl: argv and stdin go to files, the body depends on the url, the exit code is in $WORK/curl-rc
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$WORK/curl-argv"
if [ ! -t 0 ]; then cat >> "$WORK/curl-stdin"; fi
out=
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do [ "\${args[i]}" = -o ] && out=\${args[i+1]}; done
url=\${args[\${#args[@]}-1]}
rc=\$(cat "$WORK/curl-rc" 2>/dev/null || echo 0)
[ "\$rc" = 0 ] || exit "\$rc"
case "\$url" in
  */Sessions*) cat "$WORK/body.json" > "\$out" ;;
  *) cat "$WORK/body-plain.json" > "\$out" ;;
esac
EOF
chmod +x "$BIN/curl"
export HS_CURL=$BIN/curl
echo 0 > "$WORK/curl-rc"
printf '{"n":7}' > "$WORK/body-plain.json"
printf '[{"Id":"a","NowPlayingItem":{"Name":"x"}},{"Id":"b"},{"Id":"c","NowPlayingItem":{"Name":"y"}}]' > "$WORK/body.json"

$S declare jellyfin --container jellyfin --port 8096 --title Jellyfin \
  --stat 'http-json|Streams|/Sessions?activeWithinSeconds=960||count|/NowPlayingItem|stat-jellyfin|mediabrowser||int' >/dev/null 2>&1
$S declare plain --container plain --port 8080 --title Plain \
  --stat 'http-json|Up|/s|/n|||||GB|int' >/dev/null 2>&1

reset() { : > "$WORK/curl-argv"; : > "$WORK/curl-stdin"; }
row() { grep "^$1${T}" <<<"$2" || true; }

echo "-- no key yet"
reset
out=$($S stats 2>&1)
check_eq "no key file: state nokey, no value" "jellyfin${T}0${T}Streams${T}nokey${T}-${T}-" "$(row jellyfin "$out")"
check_eq "a stat without a secret still works" "plain${T}0${T}Up${T}ok${T}7${T}GB" "$(row plain "$out")"
check_eq "and is fetched without a key config" "0" "$(grep -c -x -- '-K' "$WORK/curl-argv" || true)"

echo "-- a key on stdin"
printf '%s\n' "$KEY" | $S key jellyfin --stdin >/dev/null 2>&1
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) skip "key file mode 600 (no file modes on Windows)" ;;
  *) check_eq "the key file has mode 600" "600" "$(stat -c %a "$HS_STATE_DIR/stat-jellyfin" 2>/dev/null || stat -f %Lp "$HS_STATE_DIR/stat-jellyfin")" ;;
esac
check_eq "the key is in the file" "$KEY" "$(cat "$HS_STATE_DIR/stat-jellyfin")"
reset
out=$($S stats 2>&1)
check_eq "ok: two sessions play" "jellyfin${T}0${T}Streams${T}ok${T}2${T}-" "$(row jellyfin "$out")"
check_eq "the key is on curl's stdin as a config header" "header = \"Authorization: MediaBrowser Token=\\\"$KEY\\\"\"" "$(grep MediaBrowser "$WORK/curl-stdin")"
check_eq "the key is in no argument" "0" "$(grep -c -- "$KEY" "$WORK/curl-argv" || true)"
check "curl is told to read its config from stdin" grep -qx -- '-K' "$WORK/curl-argv"
check "short timeout, no redirects, http(s) only" bash -c 'grep -qx -- "--max-redirs" "$1" && grep -qx -- "-m" "$1" && grep -qx -- "--proto" "$1"' _ "$WORK/curl-argv"
check_eq "the key is not in the environment of this test" "0" "$(env | grep -c -- "$KEY" || true)"

echo "-- the table"
out=$($S stats --table 2>&1)
check_out "table: header" "Service.*Label.*State.*Value" echo "$out"
check_out "table: value with its unit" "plain.*Up.*ok.*7 GB" echo "$out"
check_eq "the table never shows the key" "0" "$(grep -c -- "$KEY" <<<"$out" || true)"

echo "-- failures give a state and no value"
echo 28 > "$WORK/curl-rc"
out=$($S stats 2>&1)
check_eq "curl exit 28 (timeout): failed, value -" "jellyfin${T}0${T}Streams${T}failed${T}-${T}-" "$(row jellyfin "$out")"
echo 0 > "$WORK/curl-rc"
printf 'not json' > "$WORK/body.json"
out=$($S stats 2>&1)
check_eq "a body that is no JSON: failed" "jellyfin${T}0${T}Streams${T}failed${T}-${T}-" "$(row jellyfin "$out")"
printf '{"a":1}' > "$WORK/body.json"
out=$($S stats 2>&1)
check_eq "the wrong type (not a list): failed" "jellyfin${T}0${T}Streams${T}failed${T}-${T}-" "$(row jellyfin "$out")"
printf '[]' > "$WORK/body.json"
out=$($S stats 2>&1)
check_eq "an empty list counts 0" "jellyfin${T}0${T}Streams${T}ok${T}0${T}-" "$(row jellyfin "$out")"

echo "-- a key that cannot be used"
printf 'bad"key12345\n' > "$HS_STATE_DIR/stat-jellyfin"
reset
out=$($S stats 2>&1)
check_eq "a stored key with a quote is not used: failed" "jellyfin${T}0${T}Streams${T}failed${T}-${T}-" "$(row jellyfin "$out")"
check_eq "and no header is sent" "0" "$(grep -c MediaBrowser "$WORK/curl-stdin" || true)"
rm -f "$HS_STATE_DIR/stat-jellyfin"
check_out "key: a value with a quote is refused" "may only have" bash -c 'printf "%s\n" "bad\"quote12345" | '"$S"' key jellyfin --stdin'
check_out "key: too short is refused" "may only have" bash -c "echo abc | $S key jellyfin --stdin"
check_eq "and nothing is written" "no" "$([ -e "$HS_STATE_DIR/stat-jellyfin" ] && echo yes || echo no)"
check_out "key: a value on the command line is refused" "Not on the command line" $S key jellyfin "$KEY"
check_eq "and not stored" "no" "$([ -e "$HS_STATE_DIR/stat-jellyfin" ] && echo yes || echo no)"
check_out "key: a service without a key stat is refused" "no dashboard value" bash -c "echo $KEY | $S key plain --stdin"
check_out "key: without --stdin and no terminal it refuses" "terminal" bash -c "$S key jellyfin </dev/null"
printf '[{"NowPlayingItem":1}]' > "$WORK/body.json"
check_out "key: reports the value after storing" "answers with a value: 1" bash -c "echo $KEY | $S key jellyfin --stdin"

echo "-- a closed vault"
printf 'uuid\n' > "$HS_STATE_DIR/vault-uuid"
rm -f "$HS_STATE_DIR/stat-jellyfin"
ln -s "$HS_VAULT_DIR/secrets/stat-jellyfin" "$HS_STATE_DIR/stat-jellyfin"
out=$($S stats 2>&1)
if [ -L "$HS_STATE_DIR/stat-jellyfin" ]; then
  check_eq "a dangling link, vault closed: locked, not nokey" "jellyfin${T}0${T}Streams${T}locked${T}-${T}-" "$(row jellyfin "$out")"
else skip "locked state (no symlinks here)"; fi
rm -f "$HS_STATE_DIR/stat-jellyfin"
check_out "key: a closed vault says hs unlock" "hs unlock" bash -c "echo $KEY | $S key jellyfin --stdin"
rm -f "$HS_STATE_DIR/vault-uuid"

echo "-- nothing declared"
rm -f "$HS_SERVICES_DIR"/*.toml
check_out "table: nothing declared is said" "No service declares a stat" $S stats --table
check_eq "plain: nothing declared prints nothing" "" "$($S stats)"
finish
