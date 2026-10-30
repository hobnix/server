# Give the services local names

Traefik on the server answers on port 80 and gives every service a name such as `app.homeserver.ad.example.org`, so you stop typing addresses and ports.
It is for the home network only; the public proxy stays Zoraxy. The gateway proxy is a core capability (`gateway`).

## Before you start
- The server is a member of your domain: `adDomain` is set in `machine.toml` (for example `ad.example.org`). Without it there is no local domain.
- The web interface uses its own port, `webPort = 8480` (the default; `settable = false`, so edit the line in `machine.toml`, then rebuild). Traefik takes port 80.

## Switch it on
Not tested on hardware yet.

```bash
sudo hs config set capabilities '["gateway"]'
sudo hs rebuild
```

(Keep the other capabilities in the list; or edit the line `capabilities = [...]` in `machine.toml`.) Traefik now holds port 80. Links without a port still reach the web interface: it is the catch-all for every name that has no route.

## Add the wildcard DNS record once
One record makes every `<service>.homeserver.ad.example.org` point at this server. A person with the domain administrator password adds it; hs never asks for it. `hs gateway check` prints the exact command:

```bash
hs gateway check
```

On the domain controller (its address is the first nameserver of this server):

```bash
samba-tool dns add 192.168.1.2 ad.example.org '*.homeserver' A 192.168.1.10 -U Administrator
```

Or in Windows DNS Manager: zone `ad.example.org` > `homeserver` > New Host, name `*`, address `192.168.1.10`. Another DNS server works the same if it supports a wildcard under the site; one without wildcards needs one record per name.

This record was made and verified on a real Samba domain controller: `host anything.<site>.<realm>` answered with the server's address. Everything else in this guide: Not tested on hardware yet.

## Give the services local names
Not tested on hardware yet.

```bash
sudo hs services import --proxy local
sudo hs services apply --proxy local
```

`import` marks every service as wanting a local name (a service you set to `local-proxy = false` stays out). A new recipe asks nothing: its service gets a local name by itself. `hs services plan --proxy local` shows the plan.

## Names with their own DNS record
An explicit record beats the wildcard. Records an older hs wrote for containers (`hs dns sync`, removed; for example `jellyfin.homeserver.ad.example.org` and the arr apps) may still be in the zone: `hs dns list` shows them, and those names go straight to the container and not through Traefik. `hs dns clean` removes them (it shows a plan first) Not tested on hardware yet., so the names go through the gateway. The services plan says so in its note column. Give a service a second label (`names`, for example `media`) to reach it through the gateway.

## Reach the web interface
Not tested on hardware yet.

- `http://homeserver.ad.example.org/` through Traefik (also `http://192.168.1.10/` and any name without a route).
- `http://192.168.1.10:8480/` directly; it works with Traefik stopped.

## Check that it worked
Not tested on hardware yet.

```bash
hs gateway status
hs gateway check
hs gateway routes
```

## If something goes wrong
| Symptom | Cause | What to do |
| --- | --- | --- |
| `port80` is not `traefik` | another program holds port 80 | stop it, then `sudo hs rebuild` |
| A name opens the web interface | no route for that name | `hs services plan --proxy local`, then `apply` |
| A name bypasses the gateway | an explicit DNS record exists | see "Names with their own DNS record" |
| `wildcard` is `wrong` or `missing` | the record is absent or points elsewhere | `hs gateway check` prints the command |
| Routes stop updating | a hand-made file in `/var/lib/hs-gateway/routes` is broken YAML | fix or remove it |
| 502 after 30 s, IPS alert 2101201 in the router | the tunnel still goes through the router | move it to the internal link ("Move an existing tunnel to the internal link") |

## Public services through the tunnel
Optional: Traefik can also serve the public routes (paths, blocked paths, login, headers) instead of Zoraxy. Cloudflare's tunnel program (`cloudflared`) then sends the traffic to a port that only its container may reach. Not tested on hardware yet.

1. Set the port. `hs config set` does not handle this option: add the line to `/etc/nixos/machine.toml` and rebuild. Not tested on hardware yet.

```toml
gatewayTunnelPort = 8081
```

```bash
sudo hs rebuild
```

With the `incus` capability on, the cloudflared container reaches Traefik over the internal link (a host-only Incus network, no router in between) and `gatewayTunnelFrom` stays empty: an empty list means the container on the link (`10.99.0.2/32`). Without Incus, set `gatewayTunnelFrom = [ "10.99.0.2/32" ]` to the single address of the cloudflared container (a /32, or /128 for IPv6; never a whole network, that would let LAN machines forge forwarded headers).

2. Set up the cloudflared container. The recipe gives it a second network card on the internal link and prints the service address. It needs the current recipe: run `sudo hs pkg update cloudflared` first if the recipe is already installed. Not tested on hardware yet.

```bash
sudo hs recipe cloudflared
```

3. Choose the variant and apply the routes. Not tested on hardware yet.

```bash
sudo hs config set reverseProxy traefik-public
hs services plan
sudo hs services apply
```

4. In Cloudflare, set the service of every public hostname of the tunnel to `HTTP` and `10.99.0.1:8081` (the server on the internal link plus `gatewayTunnelPort`; the recipe prints the exact address, which differs when `incusInternalSubnet` is set). Not tested on hardware yet.

To go back: `hs config set reverseProxy zoraxy` and set the old origin again.

## Move an existing tunnel to the internal link
For a tunnel that works today through the router: the cloudflared recipe is installed at `10.10.95.10`, the Cloudflare service is `http://10.10.10.95:8081` and `machine.toml` has `gatewayTunnelFrom = [ "10.10.95.10/32" ]`. The old path keeps working until step 6; no step needs a reboot. None of these steps has been run on real hardware.

**The cloudflared recipe must be the version that knows the internal link (core API level 3).** Step 3 fetches it.

1. Update the server. This creates the network `hs-internal` and the firewall table; the tunnel is not changed. Not tested on hardware yet.

```bash
sudo hs update
```

Check the network and the table (there is no `hs` command for them, so the long form). Not tested on hardware yet.

```bash
incus network show hs-internal
```

```bash
sudo nft list table inet hs-internal
```

2. Allow both sources. Edit `/etc/nixos/machine.toml` by hand, then rebuild. Not tested on hardware yet.

```toml
gatewayTunnelFrom = [ "10.10.95.10/32", "10.99.0.2/32" ]
```

```bash
sudo hs rebuild
```

3. Get the new recipe version (the update shows what changed first), then run it. Not tested on hardware yet.

```bash
sudo hs pkg update cloudflared
```

```bash
sudo hs recipe cloudflared
```

The recipe keeps the token, adds a second network card (`eth1`, `10.99.0.2`), restarts the cloudflared service and prints the new service address. The tunnel may be down for a few seconds.

4. Check inside the container (`incus` is the only way in). Not tested on hardware yet.

```bash
incus exec cloudflared -- ip -4 addr show eth1
```

`10.99.0.2/29` is listed. The default route must be only via `eth0`:

```bash
incus exec cloudflared -- ip route
```

The server answers on the link when this prints `open`:

```bash
incus exec cloudflared -- timeout 5 bash -c 'exec 3<>/dev/tcp/10.99.0.1/8081' && echo open
```

5. In the Cloudflare dashboard open the tunnel, Public Hostname, and edit EVERY hostname (the wildcard and the apex) to the service `HTTP` `10.99.0.1:8081`. Load the sites many times and watch for 502 errors over a day: the old failure came and went. Not tested on hardware yet.

6. Close the old path: remove the `gatewayTunnelFrom` line from `/etc/nixos/machine.toml` (or set it to `[ "10.99.0.2/32" ]`), then rebuild. Not tested on hardware yet.

```bash
sudo hs rebuild
```

From another machine in the LAN, this must time out:

```bash
curl -m 5 http://10.10.10.95:8081/
```

To roll back before step 6, set the Cloudflare service to `HTTP` `10.10.10.95:8081` again. After step 6, put the old address back in `gatewayTunnelFrom` and rebuild.

## Public services with their own certificates (no tunnel)
Optional: Traefik can also take the internet's traffic itself and get its own certificates from Let's Encrypt, so no tunnel is needed. Tunnel-only setups stay as they are: a domain that is not listed below stays on the tunnel. Not tested on hardware yet.

**The router must forward the internet's ports 80 and 443 to this server, and port 443 must be reachable from outside.** Let's Encrypt checks each host on port 443 (TLS-ALPN-01); if it cannot connect, no certificate is issued.

1. Open the public HTTPS port, set the account address and keep staging on (the default). `hs config set` does not handle these options: add the lines to `/etc/nixos/machine.toml` (see "Entrypoints" in the gateway notes), keep `gatewayAcmeStaging` at `true`, and rebuild. Not tested on hardware yet.

```toml
gatewayPublicHttps = 443
gatewayAcmeEmail = "admin@example.org"
```

```bash
sudo hs rebuild
```

2. Name the domains served directly (a comma list; a runtime setting, no rebuild) and apply the routes. Not tested on hardware yet.

```bash
sudo hs config set gatewayDirectDomains example.org
sudo hs services apply
```

3. Test with staging first. Staging certificates are not trusted by browsers; the browser warning is expected. Not tested on hardware yet.

```bash
hs gateway status
```

`Own certificates` shows `staging`. The hosts and their state are listed with `hs sys gateway certs` (`staging`, `default`, `none` or `ok`).

4. When every host shows a staging certificate, switch to production: change the line `gatewayAcmeStaging = false` in `/etc/nixos/machine.toml` and rebuild. Staging and production certificates are stored apart, and `/var/lib/hs-gateway/acme` is part of the backup. Not tested on hardware yet.

```bash
sudo hs rebuild
```

Domains published by the extension `passthrough` keep their own certificates. To go back to the tunnel, empty `gatewayDirectDomains` and run `sudo hs services apply`.

## Next
The extension `passthrough` publishes a domain by TLS passthrough through this gateway (see its guide).
