# Gateway proxy (capability `gateway`)

Traefik on the host owns port 80 and gives every LOCAL service a name `<label>.<site>.<realm>` by Host header -> container address:port, from
the service descriptors. Zoraxy stays the PUBLIC proxy. Core capability (not an extension): on = `capabilities = ["gateway"]` + `hs rebuild`.
Commands `hs gateway status|routes|check` (scripts/gateway.sh), provider scripts/providers/reverse-proxy/traefik.sh, files rendered by
scripts/gateway_render.py (stdlib, golden tests in tests/gateway.sh), domain by scripts/lib/localdomain.sh (`local_domain`).

## Two slots, independent
- `public` = the runtime setting `reverseProxy` (zoraxy). `local` = traefik, present exactly when the capability is on.
- A descriptor wants per slot: `[want] reverse-proxy = true` (public) and `local-proxy = true`. Planning, applying and removing in one
  slot never touch the other. `make_plan(..., slot=...)` runs once per slot; the public guard code is unchanged.
- The local provider's `info` says `public no`, always; services.sh REFUSES the local slot when it says `public yes`. On a non-public
  proxy every exposure is allowed, so admin pages (ADMIN_TARGETS) may get a local route and still never a public one. `fqdn` and
  `public_paths` are ignored in the local slot: local hosts are only `<label>.<local domain>` for each label in `names`.
- `hs services plan|apply|import|adopt --proxy local`; `apply --adds-only` (declare_service) does only `add` rows, no question.
  `import --proxy local` is a migration: every descriptor without a `local-proxy` want gets `true` (a person's `false` stays).

## Entrypoints
- `lan-http` = `:80`. nftables opens 80 only for RFC1918 sources and `hs.privateInterfaces` while `gatewayPublicHttp` is not 80. Every local
  router also carries the middleware `hs-lan-only` (ipAllowList on the TCP peer address, never X-Forwarded-For; the entrypoints do not
  trust forwarded headers and do not use PROXY protocol, so Traefik sees the real client address).
- `public-https` / `public-http` exist only when `gatewayPublicHttps` / `gatewayPublicHttp` are not 0 (defaults 0, used by the extension
  passthrough). They carry ONLY passthrough routers. Decision of the user: the router forwards the internet's 443 and 80 straight to the
  server, so the values to set are `gatewayPublicHttps = 443` and `gatewayPublicHttp = 80`; 4443 and 8008 only behind a router that
  translates ports. With `gatewayPublicHttp = 80` there is NO separate `public-http` entrypoint: port 80 is `lan-http`, so the same entrypoint
  serves local names and passthrough domains and port 80 is in allowedTCPPorts (open to everyone). This is safe because (a) a local route
  answers a public source with 403 (`hs-lan-only`), (b) the two catch-all routers (`hs-webui`, `hs-fallback`) also have
  `ClientIP(<home ranges>)` in their RULE, so a public source on an unknown or the host's own name matches nothing: 404, never the web
  interface, (c) passthrough routers have long rules and win over the catch-all (priority 1), and match only their own domain.
- The web interface (`webPort = 8480`) stays reachable on its direct port and is the break-glass address. Through Traefik: router `hs-webui` for `<site>.<realm>` and the
  catch-all `hs-fallback` (priority 1) for any other Host. The bare AD apex `<realm>` is the domain's, there is no router for it.

## Paths and owners
`/var/lib/hs-gateway/routes/` (2750 root:traefik, setgid; Traefik's one watched directory, flat) and `/var/lib/hs-gateway/tmp/`
(write there, `mv` into routes: atomic). File names: `00-hs-base.yml` (symlink to the Nix store, never touched), `local-<host>.yml`
(traefik.sh), `pt-<domain>.yml` (extension passthrough), anything else is `unmanaged` and never changed. Files 0640.
**One bad YAML in ANY file makes Traefik ignore the whole directory update**: every file is rendered by gateway_render.py and moved in atomically.
The static file is `services.traefik.staticConfigFile` (nixpkgs has staticConfigFile/staticConfigOptions; setting the file ourselves keeps the
module from adding `providers.file.filename`, which cannot sit beside `directory`). No api, dashboard, ping, metrics or ACME: the dashboard would be an admin page.

## DNS
One wildcard record `*.<site>` A <host ip>, made ONCE BY A PERSON (it needs the DC administrator's password; hs never asks for it). hs only
checks it (`hs gateway check`, the first-run item `gateway-dns`). hs writes no DNS records any more (the sync was removed 2026-10-29); `hs dns clean` never touches a record whose
name is `*` or starts with `*.`. An explicit record beats the wildcard: leftovers of the old sync go straight to the container (dns.sh `raw`
feeds the explicit list); `hs services plan --proxy local` says so in the note column.

## Local HTTPS (out of scope; plug-in point)
An entrypoint `lan-https` on :443 (free, because the router forwards to 4443); local routers get `tls: {}` and a certificate from the file
provider (`tls.certificates` in a `00-hs-tls.yml`) or ACME DNS-01. The route files change only in their `entryPoints` line.

## Web interface behind Traefik
`HS_WEB_TRUST_PROXY` is set while the capability is on: Traefik sends X-Forwarded-For from 127.0.0.1 and web-serve.py trusts it only from loopback.
Risk: if web-serve ever trusts X-Forwarded-For from more than loopback the login throttle can be fooled.

## Tunnel entrypoint (reverseProxy = traefik-public)
`gatewayTunnelPort` (default 0 = off) adds the entrypoint `public-tunnel`; its trustedIPs and the firewall rule (`ip saddr { gatewayTunnelFrom } tcp dport <port> accept`, extraInputRules only, never allowedTCPPorts) are limited to `gatewayTunnelFrom`. The base file also holds `hs-deny` (ipAllowList 127.0.0.2/32, always 403) and `hs-null`. Full docs: step D.

## Direct mode with Let's Encrypt (phase 3)
`gatewayAcmeEmail` (empty = off) turns on the resolver `hs-le`: TLS-ALPN-01 only (needs the router to forward 443 to `gatewayPublicHttps`). `gatewayAcmeStaging` (default true) picks the test CA; staging and production keep separate storage under `/var/lib/hs-gateway/acme`, which is in the backup. `gatewayDirectDomains` (runtime setting, `hs services apply`, no rebuild) lists the domains served directly by `d-` routers; others stay on the tunnel. The catch-all `hs-deadend` is dropped only while ACME is on. Passthrough domains keep their own certificates. `hs sys gateway certs` prints host, state (staging|default|none|ok), until; `hs gateway status` has the rows `acme` (off|staging|production) and `public_proxy`. Not tested on hardware yet.
