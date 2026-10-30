# incus

Incus with its preseed (storage pool `default` on `fast/incus`, one profile per VLAN with the nightly snapshot), the option `incusUi`, the
nightly `hs-mac` job and the `incus-admin` group of adminuser. Needs the pool, so it requires `storage`.

- The VLAN bridges and tagged interfaces stay in configuration.nix (networking, only for `role = "homeserver"`).
- While encrypted storage is locked incus stays down (`systemd.services.incus.unitConfig = whenUnlocked`).

## Internal link `hs-internal`
A host-only Incus bridge between the server and chosen containers (cloudflared to Traefik), so that traffic never crosses the router.
Not tested on hardware yet.

- Names: the bridge name is one constant in `capabilities/incus/internal-link.nix` (Nix); `HS_LINK_BRIDGE`, `HS_LINK_DEVICE` (`hs-link`) and
  `HS_LINK_NIC` (`eth1`) are the constants in `scripts/lib/internal-link.sh` (shell). Do not repeat the strings elsewhere.
- Subnet: option `incusInternalSubnet` (default `10.99.0.0/29`, `settable = false`: edit `machine.toml`, then `hs rebuild`). The server is the
  first address (`.1`), the container the second (`.2`). A Nix assertion requires a private /29 that starts on a multiple of 8
  (10.x, 172.16-31.x, 192.168.x).
- The network is in the Incus preseed (`module.nix`, `networks`): no NAT, no DHCP, no DNS, no IPv6, no routing, `ipv4.firewall = false`.
  It is in no profile; a recipe adds it as a second NIC (device `hs-link`, `eth1`, static address, no gateway) with the helper `internal_link`
  in `scripts/recipes/_lib.sh`. UniFi reservation and `hs mac` only touch `eth0`.
- Firewall: the nft table `inet hs-internal` (priority -10, before `nixos-fw`) drops everything that arrives on the bridge except the
  entries of `hs.internalLinkAccept` (set by the gateway: the tunnel port from the link entries of `gatewayTunnelFrom`) and established
  traffic, and drops all forwarding to and from the bridge. A drop there is final, so the global `allowedTCPPorts` (22, 8443, Samba) are
  closed on the bridge too. The rules match the interface by name, so they load while the bridge does not exist.
- Facts: `/etc/hs/internal-link` (`name=`, `subnet=`, `host=`, `peer=`), read by `link_get`. `dhcpcd` is told to ignore the bridge.
- Overlap: `scripts/rebuild.sh` (`link_check`, before the build) refuses when a route or address of the running system overlaps the
  subnet (`link_overlaps`; routes shorter than /16, such as a VPN aggregate, do not count; `HS_LINK_CHECK=0` skips the check). The helper
  `internal_link` checks again before it attaches the NIC.
- While encrypted storage is locked incus is down, so the bridge and the cloudflared container are down too (the tunnel is down).
- Still to verify on the server: the preseed updates an existing network without error (`systemctl status incus-preseed` after
  `systemctl restart incus`) and Incus accepts every key above.
