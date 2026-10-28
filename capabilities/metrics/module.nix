# The capability "metrics" (capabilities/metrics/capability.toml, NOTES.md): Prometheus and two exporters on this host.
# Moved here from configuration.nix; capabilities/default.nix loads it only while the capability is on.
{ config, lib, pkgs, hs, ... }:

let
  hostName = hs.hostName;
  # How long Prometheus (on this host) keeps its numbers, and a size cap so the system disk cannot fill (machine.toml: metricsDays 30, metricsMaxGB 5)
  metricsDays = hs.machine.metricsDays;
  metricsMaxGB = hs.machine.metricsMaxGB;
in
{
  # Loaded only while the capability `metrics` is on (machine.toml `capabilities`, or the old `metrics = true`
  # that `hs recipe monitoring` adds). Two small programs hand out numbers; Prometheus (below) collects
  # them here on the host, Grafana, which draws them, lives in a container.
  #   9100  node-exporter: CPU, memory, file systems, ZFS, failed jobs, and
  #         what hs health writes to /var/lib/hs/metrics
  #   9633  smartctl-exporter: SMART values of every disk. It leaves disks in
  #         standby alone, so it doesn't keep them spinning.
  #   8444  Incus, numbers per container (switched on by the recipe)
  # Reachable from the home networks only.
  # Prometheus itself runs HERE on the host, not in the monitoring container: it must keep collecting while
  # the storage is locked (Incus down, no containers). No dependency on incus, zfs, bulk or samba and no
  # lock-marker condition; the data is on the plain system disk (/var/lib/prometheus2). Only 127.0.0.1:9090;
  # Grafana in the container reaches it through an Incus proxy device (hs recipe monitoring). Incus' own
  # numbers (8444) are a target that is simply down while Incus is down.
  # The exporters are inside this one block: `services.prometheus.exporters.x = ...` next to
  # `services.prometheus = mkIf ...` is "attribute already defined" in Nix.
  services.prometheus = {
    exporters.node = {
      enable = true;
      port = 9100;
      enabledCollectors = [ "systemd" ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/hs/metrics" ];
    };
    exporters.smartctl = {
      enable = true;
      port = 9633;
      maxInterval = "5m";
    };
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9090;
    retentionTime = "${toString metricsDays}d";
    extraFlags = [ "--storage.tsdb.retention.size=${toString metricsMaxGB}GB" ];
    globalConfig.scrape_interval = "30s";
    scrapeConfigs = [
      { job_name = "server";    # CPU, memory, file systems, ZFS, scheduled jobs, hs health (textfile)
        static_configs = [ { targets = [ "127.0.0.1:9100" ]; labels.instance = hostName; } ]; }
      { job_name = "disks";     # SMART values of every disk
        scrape_interval = "5m";
        scrape_timeout = "1m";
        static_configs = [ { targets = [ "127.0.0.1:9633" ]; labels.instance = hostName; } ]; }
      { job_name = "incus";     # every container and VM; down while the storage is locked
        metrics_path = "/1.0/metrics";
        scheme = "https";
        tls_config.insecure_skip_verify = true;
        static_configs = [ { targets = [ "127.0.0.1:8444" ]; labels.instance = hostName; } ]; }
    ];
  };

  # The exporters and Incus' numbers are reachable from the home networks only (merges with the other modules' rules)
  networking.firewall.extraInputRules = ''
    ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport { 9100, 9633, 8444 } accept
  '';

  # where `hs health` leaves its numbers for the node exporter's textfile collector
  systemd.tmpfiles.rules = [ "d /var/lib/hs/metrics 0755 root root -" ];
}
