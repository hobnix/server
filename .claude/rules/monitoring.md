---
paths:
  - "scripts/health-check.sh"
  - "scripts/notify*"
  - "scripts/state*"
  - "scripts/lib/ntfy.sh"
  - "scripts/lib/state.sh"
  - "scripts/edge-health.sh"
  - "scripts/lib/edge_facts.py"
  - "capabilities/metrics/**"
  - "capabilities/notifications/**"
  - "capabilities/edge-*/**"
  - "packages/monitoring/**"
  - "vps/**"
---

# Monitoring, notifications, graphics, bridge

Loaded when you touch the files above (path-scoped rule). The root CLAUDE.md has the rules that always apply.

- **Monitoring and status** (details: docs/Entwicklungsnotizen.md#monitoring-and-status). push messages go to CHANNELS (capability `notifications`, capabilities/notifications/NOTES.md): `hs notify channel ...`, files in /var/lib/hs/notify-channels, providers scripts/notify/<provider>.sh (the only `curl`; ntfy through scripts/lib/ntfy.sh, mirrored in the proxyserver repo, so do not change it for providers), routing in scripts/notify.sh; `notifyUrl`/`notifyUrlSecond` still work: they are the channels `main`/`second` until the first channel change writes them as files; health-check.sh (timer every 15 min) is the only alarm and sends only when the set of problems changes; every scheduled job needs `onFailure` -> `hs-notify-failure@<unit>.service`. Capacity forecasts, quiet hours, a second channel, `hs health ack` and the opt-in "notify and pause" mitigation (`autoMitigate`, never deletes or formats). The capability `metrics` (machine.toml `capabilities = ["metrics"]` or the old `metrics = true`; notes: capabilities/metrics/NOTES.md) runs node/smartctl exporters and Prometheus on the HOST (127.0.0.1:9090); Grafana/Loki live in the `monitoring` container and must never get a Zoraxy rule (anonymous viewing). `heartbeatUrl` + vps/hs-watch.sh (runs on the VPS, copy in the proxyserver repo: change both) give the outside view. `hs sys deck` status document (`deckApi`), SQLite state database /var/lib/hs/state.db (written ONLY by scripts/state-db.py via state.sh), `hs ports` (read only). The proxyserver repo carries copies of ntfy.sh, deck-serve.py and hs-watch.sh: change both.

- **Graphics** (details: docs/Entwicklungsnotizen.md#graphics). NVIDIA RTX 4060 (host driver, containers use it via `nvidia_gpu` in scripts/recipes/_lib.sh) plus the iGPU (i915, monitor). The CDI id does NOT work with Incus on NixOS; containers need `ldconfig` at boot (hs-nvidia-libs.service). Details and the Intel/AMD path are in the notes.

- Bridged traffic must not hit the host firewall: br_netfilter sysctls set to 0 (otherwise
  rpfilter drops container traffic).
