# metrics

Prometheus, the node exporter and the smartctl exporter run on the HOST (127.0.0.1:9090, :9100, :9633), switched on
by the capability `metrics` (machine.toml `capabilities = ["metrics"]`, or the old `metrics = true`). Options:
`metricsDays` (retention, default 30) and `metricsMaxGB` (size cap, default 5).

- Prometheus keeps collecting while the storage is locked: no dependency on incus, zfs, bulk or samba, data on the
  plain system disk (/var/lib/prometheus2). Incus' own numbers (:8444) are a target that is simply down while Incus is down.
- The exporters are inside the one `services.prometheus` block in module.nix: `services.prometheus.exporters.x = ...`
  next to `services.prometheus = ...` is "attribute already defined" in Nix.
- `hs health` writes /var/lib/hs/metrics (node exporter textfile collector); health-check.sh does it only when the
  capability is on.
- Grafana and Loki live in the `monitoring` container (`hs recipe monitoring`, which sets `metrics = true` itself and
  reads Prometheus through an Incus proxy device). Grafana must never get a Zoraxy rule (anonymous viewing).
- Firewall: the exporters and Incus' metrics port are open to the home networks (10/8, 172.16/12, 192.168/16) only.
