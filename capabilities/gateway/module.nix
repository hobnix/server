# The capability "gateway" (capabilities/gateway/capability.toml, NOTES.md): Traefik on the host gives every local service a name
# (<label>.<site>.<realm>) by Host header. Local routes are files in /var/lib/hs-gateway/routes (written by hs, scripts/gateway_render.py);
# this module only sets up Traefik, the folders, the base file, the firewall and the checks.
# nixpkgs shape (checked 2026-10-28): services.traefik has staticConfigFile / staticConfigOptions / dynamicConfigFile / dynamicConfigOptions,
# so the static file is set here (JSON is YAML) and the module adds no `providers.file.filename` beside our `directory`.
{ config, lib, pkgs, hs, ... }:

let
  m = hs.machine;
  pubS = m.gatewayPublicHttps;
  pubH = m.gatewayPublicHttp;
  # The tunnel entrypoint (reverseProxy = traefik-public): only the cloudflared container may reach it (firewall below).
  tun = m.gatewayTunnelPort;
  tunFrom = m.gatewayTunnelFrom;
  tunV4 = lib.filter (x: !lib.hasInfix ":" x) tunFrom;
  tunV6 = lib.filter (lib.hasInfix ":") tunFrom;
  grp = config.services.traefik.group;
  site = lib.toLower (hs.siteName or m.siteName or m.hostName);
  realm = if (m.adDomain or null) != null then lib.toLower m.adDomain.realm else "";

  # The sources that may use the local routes. Port 80 can be public too (gatewayPublicHttp = 80: the same entrypoint then also carries the
  # passthrough domains), so every local router has this list as a middleware AND the two catch-all routers have it in their rule:
  # a public source gets 403 on a local name and 404 on any other name, never the web interface.
  # 100.64.0.0/10 (Tailscale, but also the carrier-grade NAT of providers) is a LAN range only while port 80 is NOT public: with a public
  # port 80 an outside client behind CGNAT would pass. Tailscale clients then use the web interface's direct port or LAN names.
  lanRanges = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ] ++ lib.optional (pubH == 0) "100.64.0.0/10" ++ [ "127.0.0.1/32" "fc00::/7" "::1/128" ];
  lanClient = "(" + lib.concatMapStringsSep " || " (r: "ClientIP(`${r}`)") lanRanges + ")";

  static = {
    global = { checkNewVersion = false; sendAnonymousUsage = false; };
    log.level = "INFO";
    entryPoints = { lan-http.address = ":80"; }
      // lib.optionalAttrs (pubS != 0) { public-https.address = ":${toString pubS}"; }
      // lib.optionalAttrs (pubH != 0 && pubH != 80) { public-http.address = ":${toString pubH}"; }   # 80 is lan-http itself
      // lib.optionalAttrs (tun != 0) { public-tunnel = { address = ":${toString tun}"; forwardedHeaders.trustedIPs = tunFrom; }; };
    # No api, dashboard, ping, metrics or ACME: the dashboard would be an admin page.
    providers.file = { directory = "/var/lib/hs-gateway/routes"; watch = true; };
  };

  base = pkgs.writeText "00-hs-base.yml" (builtins.toJSON ({
    http = lib.recursiveUpdate {
      middlewares.hs-lan-only.ipAllowList.sourceRange = lanRanges;
      # for targets with scheme https and a self-signed certificate (LAN only)
      serversTransports.hs-insecure.insecureSkipVerify = true;
      # blocked paths of the public routes: no ipStrategy, so it matches the TCP peer (never 127.0.0.2) and always answers 403;
      # hs-null is the service behind it that is never reached
      middlewares.hs-deny.ipAllowList.sourceRange = [ "127.0.0.2/32" ];
      services.hs-null.loadBalancer.servers = [ { url = "http://127.0.0.1:1"; } ];
    } (lib.optionalAttrs m.webUi {
      services.hs-webui.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString m.webPort}"; } ];
      routers = {
        hs-fallback = { entryPoints = [ "lan-http" ]; rule = "HostRegexp(`.+`) && ${lanClient}"; priority = 1; middlewares = [ "hs-lan-only" ]; service = "hs-webui"; };
      } // lib.optionalAttrs (realm != "") {
        hs-webui = { entryPoints = [ "lan-http" ]; rule = "Host(`${site}.${realm}`) && ${lanClient}"; middlewares = [ "hs-lan-only" ]; service = "hs-webui"; };
      };
    });
  } // lib.optionalAttrs (pubS != 0) {
    # unknown SNI from the internet: closed
    tcp.routers.hs-deadend = { entryPoints = [ "public-https" ]; rule = "HostSNI(`*`)"; priority = 1; tls.passthrough = true; service = "hs-deadend"; };
    tcp.services.hs-deadend.loadBalancer.servers = [ { address = "127.0.0.1:1"; } ];
  }));
in
{
  services.traefik = {
    enable = true;
    staticConfigFile = pkgs.writeText "traefik-static.yml" (builtins.toJSON static);
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/hs-gateway 0750 root ${grp} -"
    "d /var/lib/hs-gateway/routes 2750 root ${grp} -"
    "d /var/lib/hs-gateway/tmp 2750 root ${grp} -"
    "L+ /var/lib/hs-gateway/routes/00-hs-base.yml - - - - ${base}"
  ];

  # Port 80 only for the home networks and the private interfaces, unless gatewayPublicHttp = 80 (then it is in allowedTCPPorts below and
  # open to everyone: the local routers refuse public sources themselves, see lanClient).
  networking.firewall.extraInputRules = ''
    ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport 80 accept
  '' + lib.concatMapStrings (i: ''
    iifname "${i}" tcp dport 80 accept
  '') config.hs.privateInterfaces
  # The tunnel port: only the addresses in gatewayTunnelFrom (the cloudflared container); never in allowedTCPPorts.
  + lib.optionalString (tun != 0 && tunV4 != [ ]) ''
    ip saddr { ${lib.concatStringsSep ", " tunV4} } tcp dport ${toString tun} accept
  '' + lib.optionalString (tun != 0 && tunV6 != [ ]) ''
    ip6 saddr { ${lib.concatStringsSep ", " tunV6} } tcp dport ${toString tun} accept
  '';
  networking.firewall.allowedTCPPorts = lib.optional (pubS != 0) pubS ++ lib.optional (pubH != 0) pubH;

  environment.etc."hs/gateway-lan-ranges".text = lib.concatStringsSep " " lanRanges + "
";   # for hs and the tests: who may use the local routes
  environment.etc."hs/gateway-public".text = "https=${toString pubS}\nhttp=${toString pubH}\ntunnel=${toString tun}\n";

  assertions = [
    { assertion = lib.versionAtLeast config.services.traefik.package.version "3.0";
      message = "the gateway proxy needs Traefik 3 or newer (the route files use its rule syntax): set services.traefik.package to a v3 package."; }
    { assertion = !(m.webUi && builtins.elem m.webPort [ 80 443 pubS pubH ]);
      message = "machine.toml: the gateway proxy owns port 80 (and the public ports); the web interface needs its own port: webPort = 8480."; }
    # the router forwards 443 and 80 straight to the server: 443 and 80 are the natural values; 4443 and 8008 work behind a router that translates ports
    { assertion = pubS == 0 || !(builtins.elem pubS ([ 80 22 139 445 8443 9740 m.webPort ] ++ config.services.openssh.ports));
      message = "machine.toml: gatewayPublicHttps = ${toString pubS} is a port the server already uses; suggested 443 (or 4443 behind a router that translates ports)."; }
    { assertion = pubH == 0 || !(builtins.elem pubH ([ 443 22 139 445 8443 9740 m.webPort ] ++ config.services.openssh.ports));
      message = "machine.toml: gatewayPublicHttp = ${toString pubH} is a port the server already uses; suggested 80 (or 8008 behind a router that translates ports)."; }
    # `tailscale serve --https=443` (capabilities/tailscale/module.nix) already holds 443 for the web interface
    { assertion = !(pubS == 443 && m.webUi && m.webTailscale);
      message = "machine.toml: gatewayPublicHttps = 443 clashes with webTailscale (tailscale serve holds 443): set webTailscale = false, or use another port behind a router that translates ports.";  }
    { assertion = pubS != pubH || pubS == 0;
      message = "machine.toml: gatewayPublicHttps and gatewayPublicHttp must be different ports."; }
    { assertion = tun == 0 || tunFrom != [ ];
      message = "machine.toml: gatewayTunnelFrom: the address of the cloudflared container, e.g. [ \"10.10.95.19/32\" ] (gatewayTunnelPort is set)."; }
    { assertion = tun == 0 || !(builtins.elem tun ([ 80 443 22 139 445 8443 9740 m.webPort pubS pubH ] ++ config.services.openssh.ports));
      message = "machine.toml: gatewayTunnelPort = ${toString tun} is a port the server already uses; suggested 8081."; }
    # single addresses only (/32 or /128): the tunnel port must stay closed to everyone but the cloudflared container
    { assertion = lib.all (a: builtins.match "[0-9]{1,3}(\\.[0-9]{1,3}){3}(/32)?" a != null
                              || builtins.match "[0-9a-fA-F:]+(/128)?" a != null) tunFrom;
      message = "machine.toml: gatewayTunnelFrom holds an address that is not valid or not a single host (only /32 or /128): use the address of the cloudflared container, e.g. \"10.10.95.19/32\".";  }
    { assertion = m.role != "edge";
      message = "machine.toml: the gateway proxy is for a home server (role = \"homeserver\"), not an edge node."; }
    { assertion = !((config.services.nginx.enable or false) || (config.services.caddy.enable or false) || (config.services.httpd.enable or false));
      message = "the gateway proxy owns port 80: switch off services.nginx, services.caddy and services.httpd."; }
  ];

  # Hardening. No IPAddressAllow/Deny: they filter both directions of the unit's sockets and would block the clients.
  systemd.services.traefik.serviceConfig = {
    ProtectSystem = lib.mkForce "strict";   # nixpkgs sets "full"
    ReadWritePaths = [ config.services.traefik.dataDir ];
    ReadOnlyPaths = [ "/var/lib/hs-gateway" ];
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    NoNewPrivileges = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    CapabilityBoundingSet = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
    AmbientCapabilities = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
    UMask = "0077";
  };
}
