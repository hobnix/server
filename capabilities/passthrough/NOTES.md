# passthrough

Outside domains for other people's reverse proxies on the LAN: `<domain>` and `*.<domain>` from the internet are forwarded to an address on the LAN
(TLS passthrough by SNI on the public HTTPS entrypoint, plain HTTP by Host on the public HTTP entrypoint, optional PROXY protocol v2 toward the target).
An extension package (docs/PLAN-extensions.md) on top of the capability `gateway` (`requires`): `hs ext enable passthrough`, no rebuild, no Nix module.
Commands: commands.tsv (`ext passthrough list|status|add|remove|refresh`, `sys ext passthrough ...`). Web page: `/extensions/passthrough`
(declared in capability.toml, form web/src/forms/ops/PassthroughForm.svelte).

## Ports (decision of the user)
The router forwards the internet's 443 and 80 straight to this server. The public ports are options of the gateway, never hard-coded here:
`gatewayPublicHttps` (set 443) and `gatewayPublicHttp` (set 80), both 0 = off by default; 4443 and 8008 only behind a router that translates
ports. The route files read the ports from `/etc/hs/gateway-public` (knob `HS_GATEWAY_PUBLIC_FILE`). With `gatewayPublicHttp = 80` the HTTP
routers use the entrypoint `lan-http` (it is port 80), otherwise `public-http`. The web interface stays on its direct port 8480.

## Files
Route files `/var/lib/hs-gateway/routes/pt-<domain>.yml`, rendered by passthrough.py, written to `/var/lib/hs-gateway/tmp/` and `mv`d in (one bad YAML
freezes every update of Traefik). Line 1 is a header (`# hs-gateway passthrough v1 domain= address= https= http= proxy=`) and the ONLY thing read
back. Every `start` renders all `pt-*` files again from their headers (a changed gateway-public is picked up); `hs ext passthrough refresh` does only that.

## Rules
- Targets are private LAN addresses and never this server or one of its containers (publish those with `hs services`).
- Never a domain that overlaps `proxyDomains`, a host of the public reverse proxy, the gateway's local domain (`<site>.<realm>`), the AD realm,
  a `local-*` host or another `pt-*` domain (the same domain again replaces its target).
- Only `pt-*` files are written. No middleware on purpose: these routes are public. Only the public entrypoints are used.
- Passthrough routers have long rules and win over the catch-all of the gateway (priority 1); they match only their own domain and its subdomains.
- With a public port 80, 100.64.0.0/10 is dropped from the local allowlist (capabilities/gateway/module.nix; CGNAT clients would pass). If the router rewrites the source to its own LAN address everything looks local: the guide tells how to test from mobile data.
- Traefik keeps the real client address: PROXY protocol is never used on the entrypoint itself, only (per domain, off by default) toward the target,
  on HTTPS only. On HTTP the target gets X-Forwarded-For.
- Traefik 3.3+ may log `proxyProtocol` on a TCP service as deprecated; it is kept (not tested on hardware).
- Domains over 64 characters are refused (the web confirm limit).
