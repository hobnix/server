#!/usr/bin/env bash
# help: the status document of an edge node (public VPS): mail queue, watcher, ports, certificate, Tailscale, system (one JSON object)
# help.de: das Statusdokument eines Edge-Knotens (öffentlicher VPS): Mail-Queue, Wächter, Ports, Zertifikat, Tailscale, System (ein JSON-Objekt)
# args: -
# System command (hs sys edge status), read only. The edge counterpart of scripts/deck-status.sh: the same schema 1 document with "kind": "proxyserver", plus every
# key the web pages of the proxyserver read (mail, watcher, ports, game_ports, certificate, revision, os, region, tailscale_info, settings; docs/PLAN-web-backend.md,
# "The VPS status document"). hs-edge-status.timer (capability edge-status) writes it to /run/hs-deck/deck.json every 10 s, scripts/deck-serve.py hands it out on
# port 9740 over Tailscale, and the forced command scripts/node-remote.sh answers `status` with it (hs node status). No secrets: a secret is the path of its file.
# The work is scripts/lib/edge_facts.py (standard library only). Test knobs: see the top of that file.
set -euo pipefail
exec python3 "$(dirname "$0")/lib/edge_facts.py" status
