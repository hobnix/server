# edge-ports

Public ports forwarded into the tailnet, ported from the proxyserver repo (modules/firewall.nix): the Pelican game pool to pelican-wings
(`edgeWingsIp`, `edgeGamePorts` as TCP and UDP, `edgeGameTcp` / `edgeGameUdp` for one protocol) and the Matrix call ports to LiveKit
(`edgeRtcIp`, `edgeRtcTcp`, `edgeRtcUdp`). nftables table `hs-edge-nat` (dnat + masquerade), the forward chain of the NixOS firewall drops everything
except `ct status dnat`, with MSS clamping (tailscale0 has an MTU of 1280).

- Never forward "everything": an assertion refuses a pool that covers 22, 25, 80, 2222 or 41641 (SSH, mail, the certificate check, the node's own SSH, Tailscale).
- The pool must be the same as the allocations in Pelican AND the ports the Tailscale ACL allows for this node's tag; the ACL is changed in the admin
  console, not from here (on purpose). A new block in Pelican needs both.
- An empty list leaves the rule out (an empty nft set is a syntax error); `warnings` say when a forward is switched off by a missing address.
- The status document's `ports` and `game_ports` keys are read from the live ruleset (`nft list ruleset`) and from /etc/hs/edge-ports.json.
- Not run on a real VPS yet. The NixOS options `networking.firewall.filterForward` and `extraForwardRules` need NixOS 24.11 or newer with nftables.
