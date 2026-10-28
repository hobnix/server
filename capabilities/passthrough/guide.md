# Forward outside domains

Hand a domain you do not run yourself (a cousin's, a friend's) to the reverse proxy that person runs on your network. The server only passes the traffic on; the target answers TLS itself.

## Before you start
- The gateway proxy is on (`capabilities = ["gateway"]`, see [Give the services local names](gateway.md)).
- Set the two public ports in `machine.toml` (these options are not settable by `hs config set`), then rebuild. The router forwards the internet's 443 and 80 straight to the server, so use these values:

```toml
gatewayPublicHttps = 443
gatewayPublicHttp = 80
```

```bash
sudo hs rebuild
```

The ports are options, not fixed. If your router can only translate ports, use `4443` and `8008` instead and forward 443 to 4443 and 80 to 8008. Not tested on hardware yet. These ports are open to the internet; local names on port 80 still answer only the home networks.
- DNS of `example.com` and `*.example.com` points at your public address, and the router forwards its ports 443 and 80 to the server.
- The target is a reverse proxy on the LAN at a private address, for example `192.168.1.20`.

**Router check, do it before you tell anyone it works.** Some routers (hairpin or SNAT setups, some proxy modes) rewrite the source address of forwarded traffic to their own LAN address. Then every internet client looks local and reaches the local names and the web interface. Test it: open a local name of the server, for example `https://homeserver.ad.example.org/`, from a phone on mobile data. It must answer 403 or 404, never a page. If it shows a page, turn that router feature off before you forward any domain.

Port 80 is then open to the internet. Tailscale (100.64.0.0/10) is no longer a trusted source on it: Tailscale clients use the web interface on its direct port 8480 or the LAN names. Port 443 also clashes with `webTailscale = true` (it uses 443); the rebuild refuses that.

## Switch it on
Not tested on hardware yet.

```bash
sudo hs ext enable passthrough
```

## Forward a domain
**This opens the domain and all its subdomains to the internet.** List what is forwarded first:

```bash
hs ext passthrough list
```

```bash
sudo hs ext passthrough add example.com 192.168.1.20
```

The plan shows both ports and asks once. Not tested on hardware yet. Traefik picks the route up within seconds, without a restart. A domain that overlaps one of the server's own domains is refused.

## PROXY protocol
Add `--proxy-protocol` only if the target expects it on HTTPS; without it, or with it when the target does not expect it, the target's TLS breaks. It is set per domain.

```bash
sudo hs ext passthrough add example.com 192.168.1.20 --proxy-protocol
```

## HTTPS only
`--no-http` forwards nothing on port 80. The target then needs TLS-ALPN-01 or DNS-01 to get certificates and sends no redirect from http to https.

```bash
sudo hs ext passthrough add example.com 192.168.1.20 --no-http
```

## Stop forwarding
**Visitors of the domain and its subdomains get no answer until it is added again.** You type the domain to confirm.

```bash
sudo hs ext passthrough remove example.com
```

## Check that it worked
- The list shows the domain, and the status shows who holds the public ports and whether the targets answer.

```bash
hs ext passthrough status
```

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| "no public port" | `gatewayPublicHttps` is 0 | Set it (see above), then `sudo hs rebuild` |
| The status warns about a port | Another program holds 443 or 80 | Stop it or move it; Traefik needs both |
| The status says the target is down | The proxy on the LAN is off or the address is wrong | Start it, or add the domain again with the right address |
| Certificate errors in the browser | The target's certificate, not the server's | Fix it on the target |
| Works from outside, not from the LAN | The router has no NAT loopback | Use split DNS or test from outside |
| A local name answers from the internet | The router rewrites the source address | Turn off the router's SNAT/hairpin feature, test again from mobile data |
| Unknown names show a 404 | The domain is not forwarded here | Add it |

## Next
- [Give the services local names](gateway.md)
