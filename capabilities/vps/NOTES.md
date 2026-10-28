# vps (proxyserver)

DEPRECATED (2026-10-27): the proxyserver repo is being replaced by an edge node of this repo (TODO.md section D).
This capability stays until the cutover.

The proxyserver is a separate machine (repo `proxyserver`) that is the public front door; this server only talks to it.
The capability is on when the runtime setting `vpsHost` or `proxyStatusUrl` is set (`hs config set vpsHost <host>`).

- Web pages: the `proxyserver` node of the web interface (Mail entry, Ports, Outside watcher, Certificate, Tailscale of the
  VPS, Settings; web/src/pages/Proxy*.svelte, pages/proxy/). The Ports page is `/proxy/ports` (`ports` key of the VPS status
  document, alias `/proxy/game-ports`). The status document is read from `proxyStatusUrl` (`GET /api/proxy/status`; 404 while not set).
- VPS buttons: `vpsHost` switches on `vps update` / `vps watch` on the proxyserver page: `sys vps plan|start`
  (scripts/vps-change.sh, `CHANGES["vps"]` in web-serve.py = exactly those two words) runs
  `ssh -i /var/lib/hs/vps-key ... root@<vpsHost> <verb>` as a job. The key is the vault secret `vps-key` made by `hs vps key`
  (prints only the public line and the VPS's `webKey` line); the VPS accepts it only through its forced command
  (proxyserver repo: modules/cli/vps-remote.sh, update|watch|status). Never give that key a shell or more words.
- `heartbeatUrl` + vps/hs-watch.sh (runs on the VPS, copy in the proxyserver repo: change both) give the outside view.
  The proxyserver repo also carries copies of ntfy.sh and deck-serve.py: change both.
- Nodes: `hs node` lists the VPS as the implicit node `proxyserver` while `vpsHost` is set (same key, port 2222, root);
  `hs node status proxyserver` asks the VPS forced command for `status`. Nothing above changes. Test: tests/node.sh.
- The proxyserver repo is deprecated (2026-10-27): the VPS becomes a node of this repo with `role = "edge"` and the capabilities `edge-mail`, `edge-ports`,
  `edge-watcher`, `edge-status`. This capability (`vpsHost`, `proxyStatusUrl`, `hs vps key`) keeps working for the OLD VPS until the cutover checklist
  there is done; the new node is read with `hs node status <name>` (node kind `edge`). Nothing above changed.
- Tests: tests/web-proxy.sh, tests/web-vps.sh, tests/vps-watch.sh.
