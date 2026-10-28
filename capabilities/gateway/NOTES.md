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
- `lan-http` = `:80`. nftables opens 80 only for RFC1918 sources and `hs.privateInterfaces`; port 80 is NOT in allowedTCPPorts. Every local
  router also carries the middleware `hs-lan-only` (ipAllowList on the TCP peer address, never X-Forwarded-For).
- `public-https` / `public-http` exist only when `gatewayPublicHttps` / `gatewayPublicHttp` are not 0 (defaults 0, used by the extension
  passthrough). They carry ONLY passthrough routers; the router must translate the internet's 443 -> server:4443 and 80 -> server:8008
  (OPEN: the user has not confirmed the router can translate ports; fallback not specified: one shared :80/:443 with the allowlist only).
- The web interface (`webPort = 8480`) is the direct and break-glass address. Through Traefik: router `hs-webui` for `<site>.<realm>` and the
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
checks it (`hs gateway check`, the first-run item `gateway-dns`). `hs dns sync` never plans, changes or removes a record whose name is `*` or
starts with `*.` (dns.sh `is_hand`). An explicit record beats the wildcard: names `hs dns sync` writes for containers go straight to the
container; `hs services plan --proxy local` says so in the note column.

## Local HTTPS (out of scope; plug-in point)
An entrypoint `lan-https` on :443 (free, because the router forwards to 4443); local routers get `tls: {}` and a certificate from the file
provider (`tls.certificates` in a `00-hs-tls.yml`) or ACME DNS-01. The route files change only in their `entryPoints` line.

## Web interface behind Traefik
`HS_WEB_TRUST_PROXY` is set while the capability is on: Traefik sends X-Forwarded-For from 127.0.0.1 and web-serve.py trusts it only from loopback.
Risk: if web-serve ever trusts X-Forwarded-For from more than loopback the login throttle can be fooled.
