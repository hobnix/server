# The capability "edge-ports" (capabilities/edge-ports/NOTES.md): this node forwards public ports to hosts inside the tailnet. Ported from the proxyserver
# repo (modules/firewall.nix): nftables dnat of the game ports to pelican-wings and of the Matrix call ports to LiveKit, with masquerade on the way back
# and MSS clamping (tailscale0 has an MTU of 1280, the public side 1500). Nothing else is ever forwarded: 22, 25, 80, 2222 and 41641 stay this node's own.
{ config, lib, pkgs, hs, ... }:

let
  m = hs.machine;
  wings = m.edgeWingsIp;
  rtc = m.edgeRtcIp;
  str = map toString;
  # The pool is forwarded as TCP and UDP (Pelican publishes both for every allocation); gameTcp / gameUdp are for ports that need one protocol.
  gameTcp = str (m.edgeGamePorts ++ m.edgeGameTcp);
  gameUdp = str (m.edgeGamePorts ++ m.edgeGameUdp);
  rtcTcp = lib.optionals (rtc != "") (str m.edgeRtcTcp);
  rtcUdp = lib.optionals (rtc != "") (str m.edgeRtcUdp);

  # nft sets: `{ 25565, 25570-25575 }`. An empty set is a syntax error, so a rule with no ports is left out instead.
  set = ports: "{ ${lib.concatStringsSep ", " ports} }";
  rule = stmt: ports: lib.optionalString (ports != [ ]) stmt;

  well = s: builtins.match "[0-9]+(-[0-9]+)?" s != null;
  span = s: let p = lib.splitString "-" s; in { lo = lib.toInt (lib.head p); hi = lib.toInt (lib.last p); };
  covers = port: s: let r = span s; in r.lo <= port && port <= r.hi;
  ownPorts = [ 22 25 80 2222 41641 ];
  forwarded = gameTcp ++ gameUdp ++ rtcTcp ++ rtcUdp;
  clash = lib.filter (p: lib.any (covers p) (lib.filter well forwarded)) ownPorts;
in
{
  assertions = [
    {
      assertion = lib.all well forwarded;
      message = "machine.toml: a forwarded port must be a number or a range such as \"25565-25579\".";
    }
    {
      assertion = clash == [ ];
      message = "machine.toml: the forwarded ports (edgeGamePorts, edgeGameTcp, edgeGameUdp, edgeRtcTcp, edgeRtcUdp) include ${lib.concatMapStringsSep ", " toString clash}: those stay this node's own (SSH, mail, the certificate check, Tailscale). Never forward everything.";
    }
  ];
  warnings =
    lib.optional ((gameTcp != [ ] || gameUdp != [ ]) && wings == "") "edgeWingsIp is empty: the game ports are not forwarded"
    ++ lib.optional (wings != "" && gameTcp == [ ] && gameUdp == [ ]) "no game ports are forwarded (edgeGamePorts is empty)"
    ++ lib.optional (rtc != "" && rtcTcp == [ ] && rtcUdp == [ ]) "edgeRtcIp is set but edgeRtcTcp and edgeRtcUdp are empty: no Matrix call ports are forwarded";

  # what scripts/lib/edge_facts.py (status document: ports page) reads; no secrets
  environment.etc."hs/edge-ports.json".text = builtins.toJSON {
    wingsIp = wings;
    gamePorts = str m.edgeGamePorts;
    gameTcp = str m.edgeGameTcp;
    gameUdp = str m.edgeGameUdp;
    rtcIp = rtc;
    rtcTcp = str m.edgeRtcTcp;
    rtcUdp = str m.edgeRtcUdp;
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    # forwarded packets come back through tailscale0; strict reverse-path filtering would drop them
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
  };

  # The forward chain of the NixOS firewall drops everything except what a dnat rule rewrote (ct status dnat); the TCP segment size is clamped to the
  # route's MTU so big packets of a forwarded connection are not lost.
  networking.firewall.filterForward = true;
  networking.firewall.extraForwardRules = ''
    tcp flags syn tcp option maxseg size set rt mtu
    ct status dnat accept
  '';

  # A connection to the public address is rewritten to the Tailscale address of the target; masquerade brings the answer back the same way.
  networking.nftables.tables.hs-edge-nat = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat;
        ${rule "iifname != \"tailscale0\" tcp dport ${set gameTcp} dnat to ${wings}" (lib.optionals (wings != "") gameTcp)}
        ${rule "iifname != \"tailscale0\" udp dport ${set gameUdp} dnat to ${wings}" (lib.optionals (wings != "") gameUdp)}
        ${rule "iifname != \"tailscale0\" tcp dport ${set rtcTcp} dnat to ${rtc}" rtcTcp}
        ${rule "iifname != \"tailscale0\" udp dport ${set rtcUdp} dnat to ${rtc}" rtcUdp}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "tailscale0" masquerade
      }
    '';
  };
}
