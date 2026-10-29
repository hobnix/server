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

## Next
The extension `passthrough` publishes a domain by TLS passthrough through this gateway (see its guide).
