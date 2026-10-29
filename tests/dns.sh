#!/usr/bin/env bash
# hs dns: list and sync the instance names under <siteName>.<domain>, against a fake incus / samba-tool. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_MACHINE_FILE=$WORK/machine.toml HS_SITE_NAME_FILE=$WORK/site-name HS_HOST_IP=10.10.10.95
export HS_INCUS=$WORK/incus HS_MANAGE_CT=$WORK/manage-ct.sh
D="bash $SCRIPTS/dns.sh"

cat > "$HS_MACHINE_FILE" <<'NIX'
hostName = "homeserver"
adDomain = { realm = "AD.HOME.LAN", workgroup = "HOME" }
NIX
echo home > "$HS_SITE_NAME_FILE"

# the instances (name, type, state, address)
cat > "$HS_MANAGE_CT" <<'EOF2'
#!/usr/bin/env bash
printf 'docs\tcontainer\tRunning\t10.10.95.22\n'
printf 'docker\tcontainer\tRunning\t10.10.95.20\n'
printf 'dc1\tvm\tRunning\t10.10.95.40\n'
printf 'sleeper\tcontainer\tStopped\t-\n'
EOF2
# a fake incus: `info` works, samba-tool queries print $WORK/zone.out, changes are logged
cat > "$HS_INCUS" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = info ] && exit 0
[ "$1" = list ] && exit 0   # dc_name asks which instances exist (nothing: dc1)
# exec dc1 -- samba-tool dns <verb> 127.0.0.1 <zone> <args...> -P
verb=$6; shift 8
if [ "$verb" = query ]; then cat "$WORK_ZONE" 2>/dev/null; exit 0; fi
echo "$verb ${*%-P}" >> "$WORK_CALLS"
EOF2
chmod +x "$HS_INCUS" "$HS_MANAGE_CT"
export WORK_ZONE=$WORK/zone.out WORK_CALLS=$WORK/calls.log

echo "-- an empty zone: everything is added"
: > "$WORK_ZONE"
check_out "the plan names every record" "add +docs.home.ad.home.lan +A +10.10.95.22" $D sync --dry-run
check_out "the host and incus" "incus.home.ad.home.lan +A +10.10.10.95" $D sync --dry-run
check_out "arcane is an alias of docker" "arcane.home.ad.home.lan +CNAME +docker.home.ad.home.lan" $D sync --dry-run
check "a stopped instance gets none" bash -c "! $D sync --dry-run | grep -q sleeper"
check "the controller is left out" bash -c "! $D sync --dry-run | grep -q 'dc1.home'"
check "dry run changes nothing" test ! -s "$WORK_CALLS"
check_out "no terminal and no --yes: refused" "without --yes" $D sync
check "still nothing changed" test ! -s "$WORK_CALLS"
check_out "with --yes" "5 changes made" $D sync --yes
check_eq "five adds" "5" "$(grep -c '^add ' "$WORK_CALLS")"
check_out "an A record is added with the address" "^add docs.home A 10.10.95.22" cat "$WORK_CALLS"

echo "-- a zone that is partly right"
: > "$WORK_CALLS"
cat > "$WORK_ZONE" <<'ZONE'
  Name=, Records=1, Children=0
    A: 10.10.10.95 (flags=f0, serial=1, ttl=900)
  Name=docs, Records=1, Children=0
    A: 10.10.95.99 (flags=f0, serial=2, ttl=900)
  Name=docker, Records=1, Children=0
    A: 10.10.95.20 (flags=f0, serial=3, ttl=900)
  Name=old, Records=1, Children=0
    A: 10.10.95.77 (flags=f0, serial=4, ttl=900)
  Name=incus, Records=1, Children=0
    A: 10.10.10.95 (flags=f0, serial=5, ttl=900)
  Name=arcane, Records=1, Children=0
    CNAME: docker.home.ad.home.lan. (flags=f0, serial=6, ttl=900)
ZONE
check_out "a changed address shows its old value" "change +docs.home.ad.home.lan.*10.10.95.22.*was 10.10.95.99" $D sync --dry-run
check_out "a record that no instance has is removed" "remove +old.home.ad.home.lan" $D sync --dry-run
check "right records are not touched" bash -c "! $D sync --dry-run | grep -E 'docker.home|incus.home|arcane.home'"
check_out "2 changes" "2 changes made" $D sync --yes
check_out "the old address is given to update" "^update docs.home A 10.10.95.99 10.10.95.22" cat "$WORK_CALLS"
check_out "the stale record is deleted" "^delete old.home A 10.10.95.77" cat "$WORK_CALLS"

echo "-- up to date"
: > "$WORK_CALLS"
cat > "$WORK_ZONE" <<'ZONE'
  Name=, Records=1, Children=0
    A: 10.10.10.95 (flags=f0, serial=1, ttl=900)
  Name=docs, Records=1, Children=0
    A: 10.10.95.22 (flags=f0, serial=2, ttl=900)
  Name=docker, Records=1, Children=0
    A: 10.10.95.20 (flags=f0, serial=3, ttl=900)
  Name=incus, Records=1, Children=0
    A: 10.10.10.95 (flags=f0, serial=5, ttl=900)
  Name=arcane, Records=1, Children=0
    CNAME: docker.home.ad.home.lan. (flags=f0, serial=6, ttl=900)
ZONE
check_out "nothing to do" "up to date \(5 records\)" $D sync
check_out "list shows the full names" "docs.home.ad.home.lan +A +10.10.95.22" $D list

echo "-- the hand-made wildcard *.<siteName> (gateway proxy) is never planned"
cp "$WORK_ZONE" "$WORK/zone.keep"
printf '  Name=*, Records=1, Children=0\n    A: 10.10.10.95 (flags=f0, serial=9, ttl=900)\n' >> "$WORK_ZONE"
check_eq "sync --plain: no row for the wildcard" "" "$($D sync --plain)"
check_out "up to date with a wildcard present" "up to date" $D sync
check_out "list and raw still show it" '\*\.home\.ad\.home\.lan +A' $D list
check_out "raw keeps its three columns" '^\*\.home\.ad\.home\.lan.A.10\.10\.10\.95$' $D raw
sed -i 's/serial=9/serial=9/; $ s/10.10.10.95/10.10.10.1/' "$WORK_ZONE"
check_eq "a wildcard with another value is left alone too" "" "$($D sync --plain)"
cp "$WORK/zone.keep" "$WORK_ZONE"

echo "-- machine-readable (hs sys dns list, hs sys dns plan)"
check_eq "raw: name, type, value, no header" "$(printf 'arcane.home.ad.home.lan\tCNAME\tdocker.home.ad.home.lan\ndocker.home.ad.home.lan\tA\t10.10.95.20\ndocs.home.ad.home.lan\tA\t10.10.95.22\nhome.ad.home.lan\tA\t10.10.10.95\nincus.home.ad.home.lan\tA\t10.10.10.95')" "$($D raw)"
check_eq "sync --plain prints nothing when the names are up to date" "" "$($D sync --plain)"
sed -i 's/10.10.95.22/10.10.95.99/' "$WORK_ZONE"
check_eq "sync --plain: act, name, type, value, old; nothing changed" "$(printf 'change\tdocs.home.ad.home.lan\tA\t10.10.95.22\t10.10.95.99')" "$($D sync --plain)"
check "--plain changed nothing" test ! -s "$WORK_CALLS"

echo "-- wrong settings"
echo "Bad_Name" > "$HS_SITE_NAME_FILE"
check_out "a bad siteName" "not a name for DNS" $D list
echo home > "$HS_SITE_NAME_FILE"
printf 'hostName = "x"\n' > "$HS_MACHINE_FILE"
check_out "no domain" "no domain \(adDomain\)" $D list
finish
