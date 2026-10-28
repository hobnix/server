#!/usr/bin/env bash
# The backup disk (ext4, label "backup", unmounted between runs) must not be offered
# by `temp-disk.sh raw`; an ordinary ext4 disk still is. Fake lsblk, no root needed.
# usage: bash tests/backup-disk-hidden.sh   (needs jq)
set -euo pipefail
if ! command -v jq >/dev/null 2>&1; then echo "skip  needs jq"; [ -n "${REQUIRE_ALL:-}" ] && exit 1; exit 77; fi
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"blockdevices": [
 {"name":"sdx","pkname":null,"path":"/dev/sdx","type":"disk","fstype":null,"label":null,"size":4000787030016,"mountpoints":[null]},
 {"name":"sdx1","pkname":"sdx","path":"/dev/sdx1","type":"part","fstype":"ext4","label":"backup","size":4000787030016,"mountpoints":[null]},
 {"name":"sdy","pkname":null,"path":"/dev/sdy","type":"disk","fstype":null,"label":null,"size":2000398934016,"mountpoints":[null]},
 {"name":"sdy1","pkname":"sdy","path":"/dev/sdy1","type":"part","fstype":"ext4","label":"photos","size":2000398934016,"mountpoints":[null]}
]}
JSON
EOF
chmod +x "$tmp/bin/lsblk"
out=$(PATH="$tmp/bin:$PATH" bash "$here/scripts/temp-disk.sh" raw)
grep -q '^/dev/sdy1|ext4|photos|' <<<"$out" || { echo "FAIL: ordinary disk not offered: $out"; exit 1; }
if grep -q 'sdx' <<<"$out"; then echo "FAIL: backup disk offered: $out"; exit 1; fi
echo "ok: backup disk is not offered by temp-disk.sh"
