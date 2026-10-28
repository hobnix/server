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
  grp = config.services.traefik.group;
  site = lib.toLower (hs.siteName or m.siteName or m.hostName);
  realm = if (m.adDomain or null) != null then lib.toLower m.adDomain.realm else "";

  static = {
    global = { checkNewVersion = false; sendAnonymousUsage = false; };
    log.level = "INFO";
    entryPoints = { lan-http.address = ":80"; }
      // lib.optionalAttrs (pubS != 0) { public-https.address = ":${toString pubS}"; }
      // lib.optionalAttrs (pubH != 0) { public-http.address = ":${toString pubH}"; };
    # No api, dashboard, ping, metrics or ACME: the dashboard would be an admin page.
    providers.file = { directory = "/var/lib/hs-gateway/routes"; watch = true; };
  };

  base = pkgs.writeText "00-hs-base.yml" (builtins.toJSON ({
    http = {
      middlewares.hs-lan-only.ipAllowList.sourceRange = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "127.0.0.1/32" "fc00::/7" "::1/128" ];
      # for targets with scheme https and a self-signed certificate (LAN only)
      serversTransports.hs-insecure.insecureSkipVerify = true;
    } // lib.optionalAttrs m.webUi {
      services.hs-webui.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString m.webPort}"; } ];
      routers = {
        hs-fallback = { entryPoints = [ "lan-http" ]; rule = "HostRegexp(`.+`)"; priority = 1; middlewares = [ "hs-lan-only" ]; service = "hs-webui"; };
      } // lib.optionalAttrs (realm != "") {
        hs-webui = { entryPoints = [ "lan-http" ]; rule = "Host(`${site}.${realm}`)"; middlewares = [ "hs-lan-only" ]; service = "hs-webui"; };
      };
    };
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

  # Port 80 only for the home networks and the private interfaces; it is NOT in allowedTCPPorts (that would open it to the internet).
  networking.firewall.extraInputRules = ''
    ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport 80 accept
  '' + lib.concatMapStrings (i: ''
    iifname "${i}" tcp dport 80 accept
  '') config.hs.privateInterfaces;
  networking.firewall.allowedTCPPorts = lib.optional (pubS != 0) pubS ++ lib.optional (pubH != 0) pubH;

  environment.etc."hs/gateway-public".text = "https=${toString pubS}\nhttp=${toString pubH}\n";

  assertions = [
    { assertion = lib.versionAtLeast config.services.traefik.package.version "3.0";
      message = "the gateway proxy needs Traefik 3 or newer (the route files use its rule syntax): set services.traefik.package to a v3 package."; }
    { assertion = !(m.webUi && builtins.elem m.webPort [ 80 443 pubS pubH ]);
      message = "machine.toml: the gateway proxy owns port 80 (and the public ports); the web interface needs its own port: webPort = 8480."; }
    { assertion = pubS == 0 || !(builtins.elem pubS [ 80 443 22 445 8443 9740 m.webPort ]);
      message = "machine.toml: gatewayPublicHttps = ${toString pubS} is a port the server already uses; suggested 4443."; }
    { assertion = pubH == 0 || !(builtins.elem pubH [ 80 443 22 445 8443 9740 m.webPort ]);
      message = "machine.toml: gatewayPublicHttp = ${toString pubH} is a port the server already uses; suggested 8008."; }
    { assertion = pubS != pubH || pubS == 0;
      message = "machine.toml: gatewayPublicHttps and gatewayPublicHttp must be different ports."; }
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
