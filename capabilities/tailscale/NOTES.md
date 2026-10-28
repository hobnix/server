# tailscale (host)

This server in a tailnet, switched on by the capability `tailscale` (machine.toml `capabilities = ["tailscale"]`, or the old
switches `tailscaleRouter = true` / `webTailscale = true`). Do not confuse it with the Tailscale page of the `vps` capability:
that one shows the PROXYSERVER's tailnet.

- It is a provider of `private-access`: the module sets `hs.privateInterfaces = [ "tailscale0" ]` (option declared in
  capabilities/options.nix). The web interface (port or 443 with `webTailscale`), the status document (9740, `deckApi`) and SSH
  (when `sshOverIp = false`) are opened on those interfaces; configuration.nix never names `tailscale0` any more. A second
  provider (another VPN) would only have to add its interface to the list.
- `sshOverIp = false` closes port 22 on the network cards, so SSH works only on the private interfaces: configuration.nix refuses that
  setting while no capability provides private-access (it would lock you out).
- Only the program is set up by Nix. Joining the tailnet and the routes are done by hand once:
  `sudo tailscale up --advertise-routes=10.10.95.0/24,10.10.10.95/32 --accept-dns=false`. `tailscaleRouter` turns on IP forwarding
  and the loose reverse-path check (useRoutingFeatures "server").
- `webTailscale`: `tailscale serve` (unit hs-web-tailscale) terminates TLS with the certificate Tailscale issues for this machine
  (`https://<host>.<tailnet>.ts.net`, tailnet members only); hs-web then listens on loopback only (unless `webLan`) and trusts the
  proxy for the client address. Needs "HTTPS certificates" switched on in the Tailscale admin console. Not the internet: no funnel, no Zoraxy rule.
- Games are not tunneled: friends use Tailscale node sharing; the ACL allows autogroup:shared all ports except tcp 2022 (SFTP) and 8080 (Wings API).
