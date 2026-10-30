# shellcheck shell=bash
# The names of the internal link, defined ONCE for the shell side (the Nix side has its own single constant in capabilities/incus/internal-link.nix):
# the Incus bridge on the host, the NIC device in the instance and the interface name inside it.
HS_LINK_BRIDGE=hs-internal
HS_LINK_DEVICE=hs-link
HS_LINK_NIC=eth1
# The internal link of Incus (capabilities/incus/NOTES.md): facts from /etc/hs/internal-link (written by capabilities/incus/module.nix)
# and the overlap check used by hs rebuild and the recipe helper internal_link. Test knobs: HS_ETC_DIR, HS_IP (the ip command), HS_REPO.
link_get() {   # link_get <name|subnet|host|peer>: empty when the file or key is missing
  sed -n "s/^$1=//p" "${HS_ETC_DIR:-/etc/hs}/internal-link" 2>/dev/null | head -n 1 || true
}
# the subnet the NEXT rebuild uses: machine.toml, else the schema default from the generated config/defaults.nix
link_subnet_wanted() {
  local v; v=$(machine_get incusInternalSubnet 2>/dev/null || true)
  [ -n "$v" ] || v=$(sed -n 's/^  incusInternalSubnet = "\(.*\)";$/\1/p' "${HS_REPO:-/etc/nixos}/config/defaults.nix" 2>/dev/null || true)
  printf '%s' "$v"
}
# link_overlaps <subnet>: prints the routes and addresses (not on hs-internal) that overlap <subnet>; returns 0 when there are some.
# A route shorter than /16 (a VPN aggregate such as 10.0.0.0/8) is not counted: the /29 only takes those few addresses from it.
link_overlaps() {
  local dev; dev=$(link_get name); dev=${dev:-$HS_LINK_BRIDGE}
  { "${HS_IP:-ip}" -4 -o route show table all; "${HS_IP:-ip}" -4 -o addr show; } 2>/dev/null | python3 -I -c '
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False); dev = sys.argv[2]
types = {"local", "broadcast", "unicast", "anycast", "multicast", "unreachable", "blackhole", "prohibit", "throw", "nat"}
hit = []
for line in sys.stdin:
    w = line.split()
    if not w:
        continue
    if "inet" in w:                       # ip -o addr: "3: br0    inet 10.10.10.95/24 ..."
        if len(w) > 1 and w[1] == dev:
            continue
        cand, is_addr = w[w.index("inet") + 1], True
    else:
        if "dev" in w and w.index("dev") + 1 < len(w) and w[w.index("dev") + 1] == dev:
            continue
        cand, is_addr = (w[1] if w[0] in types and len(w) > 1 else w[0]), False
    if cand == "default":
        continue
    try:
        other = ipaddress.ip_network(cand, strict=False)
    except ValueError:
        continue
    if not is_addr and other.prefixlen < 16:
        continue
    if other.overlaps(net):
        hit.append(line.strip())
print("\n".join(hit))
sys.exit(0 if hit else 1)' "$1" "$dev"
}