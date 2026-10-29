#!/usr/bin/env bash
# hs dns: list the names and clean the leftovers of the old sync under <siteName>.<domain>, against a fake incus / samba-tool. No root needed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
export HS_LANG=en HS_PLAIN=1 HS_CALLER=test
export HS_MACHINE_FILE=$WORK/machine.toml HS_SITE_NAME_FILE=$WORK/site-name
export HS_INCUS=$WORK/incus
D="bash $SCRIPTS/dns.sh"

cat > "$HS_MACHINE_FILE" <<'NIX'
hostName = "homeserver"
adDomain = { realm = "AD.HOME.LAN", workgroup = "HOME" }
NIX
echo home > "$HS_SITE_NAME_FILE"

# a fake incus: `info` works, samba-tool queries print $WORK/zone.out, changes are logged
cat > "$HS_INCUS" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = info ] && exit 0
[ "$1" = list ] && { printf '%s
' docs docker; exit 0; }   # dc_name asks which instances exist (nothing named dc: dc1)
# exec dc1 -- samba-tool dns <verb> 127.0.0.1 <zone> <args...> -P
verb=$6; shift 8
if [ "$verb" = query ]; then cat "$WORK_ZONE" 2>/dev/null; exit 0; fi
echo "$verb ${*%-P}" >> "$WORK_CALLS"
EOF2
chmod +x "$HS_INCUS"
export WORK_ZONE=$WORK/zone.out WORK_CALLS=$WORK/calls.log


echo "-- list and raw"
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
check_out "list shows the full names" "docs.home.ad.home.lan +A +10.10.95.22" $D list
check_eq "raw: name, type, value, no header" "$(printf 'arcane.home.ad.home.lan\tCNAME\tdocker.home.ad.home.lan\ndocker.home.ad.home.lan\tA\t10.10.95.20\ndocs.home.ad.home.lan\tA\t10.10.95.22\nhome.ad.home.lan\tA\t10.10.10.95\nincus.home.ad.home.lan\tA\t10.10.10.95')" "$($D raw)"
check_out "sync is gone" "usage" $D sync

echo "-- the hand-made wildcard *.<siteName> (gateway proxy) is shown"
cp "$WORK_ZONE" "$WORK/zone.keep"
printf '  Name=*, Records=1, Children=0\n    A: 10.10.10.95 (flags=f0, serial=9, ttl=900)\n' >> "$WORK_ZONE"
check_out "list shows it" '\*\.home\.ad\.home\.lan +A' $D list
check_out "raw keeps its three columns" '^\*\.home\.ad\.home\.lan.A.10\.10\.10\.95$' $D raw

echo "-- clean: only what the old sync wrote, never the wildcard"
printf '  Name=nas, Records=1, Children=0
    A: 10.10.95.77 (flags=f0, serial=11, ttl=900)
  Name=media, Records=1, Children=0
    CNAME: jellyfin.home.ad.home.lan. (flags=f0, serial=12, ttl=900)
  Name=radarr, Records=1, Children=0
    A: 10.10.95.40 (flags=f0, serial=13, ttl=900)
' >> "$WORK_ZONE"
printf '  Name=deep.sub, Records=1, Children=0\n    A: 10.10.95.5 (flags=f0, serial=10, ttl=900)\n' >> "$WORK_ZONE"
check_out "the plan names the records" "remove +docs.home.ad.home.lan +A +10.10.95.22" $D clean --dry-run
check_out "the apex and the alias are in it" "remove +home.ad.home.lan +A" $D clean --dry-run
check "the wildcard is not planned" bash -c "! $D clean --dry-run | grep -q '\*'"
check "a hand-made nas record is not planned" bash -c "! $D clean --dry-run | grep -q nas"
check "a hand-made media CNAME is not planned" bash -c "! $D clean --dry-run | grep -q media"
check_out "an arr alias is planned" "remove +radarr.home.ad.home.lan +A" $D clean --dry-run
check "a deeper name is not planned" bash -c "! $D clean --dry-run | grep -q deep"
check "dry run changes nothing" test ! -s "$WORK_CALLS"
check_out "no terminal and no --yes: refused" "without --yes" $D clean
check "still nothing changed" test ! -s "$WORK_CALLS"
check_out "with --yes" "6 names removed" $D clean --yes
check_eq "six deletes" "6" "$(grep -c '^delete ' "$WORK_CALLS")"
check_out "a delete names the value" "^delete docs.home A 10.10.95.22" cat "$WORK_CALLS"
check "the wildcard is never deleted" bash -c "! grep -q '^delete \*' '$WORK_CALLS'"
: > "$WORK_ZONE"
printf '  Name=*, Records=1, Children=0\n    A: 10.10.10.95 (flags=f0, serial=9, ttl=900)\n' > "$WORK_ZONE"
check_out "nothing left: said so" "No leftover names" $D clean --yes

echo "-- wrong settings"
echo "Bad_Name" > "$HS_SITE_NAME_FILE"
check_out "a bad siteName" "not a name for DNS" $D list
echo home > "$HS_SITE_NAME_FILE"
printf 'hostName = "x"\n' > "$HS_MACHINE_FILE"
check_out "no domain" "no domain \(adDomain\)" $D list
finish
