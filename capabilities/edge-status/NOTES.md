# edge-status

The status document of an edge node, ported from the proxyserver repo (modules/deck.nix, `ps-deck-status`, `ps-deck-api`) and extended with every key the
web pages of the proxyserver read (docs/PLAN-web-backend.md, "The VPS status document"): `mail`, `watcher`, `ports`, `game_ports`, `certificate`,
`revision`, `os`, `region`, `tailscale_info`, `settings`.

- `hs sys edge status` (scripts/edge-status.sh over scripts/lib/edge_facts.py, standard library only) builds it. `hs-edge-status.timer` (10 s) writes
  /run/hs-deck/deck.json; `hs-edge-api` serves it read only on port 9740 over Tailscale (the SAME scripts/deck-serve.py as the home server: the copy is gone);
  the forced command scripts/node-remote.sh answers `status` with it, so the main node reads it with `hs node status <name>` (node kind `edge`, root, port 2222).
- The Tailscale ACL (admin console) must allow tcp 9740 from the main node to the node's tag. Port 9740 has no rule on the public side.
- No secrets in the document: a secret appears as the path of its file. `kind` stays "proxyserver" so the existing pages keep working.
- Not ported: `history` (24 hourly cpu/mem samples; the home server keeps them in the state database, an edge node has none), and the old `vps update|watch`
  words of the forced command (scripts/node-remote.sh answers `status` only).
- Also here: OnFailure push messages for tailscaled, nftables and sshd (postfix has its own in edge-mail).
- Test: tests/edge-facts.sh.
