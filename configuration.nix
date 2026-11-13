{ config, pkgs, lib, ... }:

let
  # Machine-specific values live in ./machine.toml (layout: machine.toml.example), so this file
  # can be replaced on updates without touching them.
  # The defaults of the options are written down once, in config/schema.toml (config/defaults.nix is made from it);
  # what machine.toml says wins. Options whose default refers to another setting (siteName) keep an `or` below.
  machine = import ./config/defaults.nix // (if builtins.pathExists ./machine.toml
    then builtins.fromTOML (builtins.readFile ./machine.toml)
    else import ./machine.nix);   # an old server until `hs config migrate` has run
  inherit (machine) nic hostId sshKeys smbAllow vlans;
  # Optional values with defaults, so an older machine.toml keeps working.
  hostName = machine.hostName;
  # Optional Active Directory membership: { realm = "AD.HOME.LAN"; workgroup = "HOME"; }
  # Logins and groups then come from the domain. Without it, the admin user (adminUser, default adminuser) is the
  # only Samba login (password: sudo smbpasswd -a <adminUser>).
  ad = machine.adDomain;
  # How /bulk is built. "zfs": a pool like fast (mirror pairs). "snapraid":
  # single disks of any size, merged with mergerfs, protected by SnapRAID parity.
  bulkType = machine.bulkType;
  bulkSnapraid = bulkType == "snapraid";
  # what has to be up before anything touches /bulk
  bulkReady = if bulkSnapraid then "bulk-mount.service" else "zfs-mount.service";
  # Hours between two parity syncs (machine.toml: syncEveryHours, default 24 = once a night at 03:00, so the HDDs can sleep
  # the rest of the day; 4 = 03 07 11 15 19 23).
  syncEveryHours = machine.syncEveryHours;
  # Incus web UI and the network address of the Incus API (machine.toml: incusUi, default true)
  incusUi = machine.incusUi;
  sshOverIp = machine.sshOverIp;
  # The label in front of the domain for this server's local names (machine.toml: siteName, default hostName); the gateway's local names are <service>.<siteName>.<domain>
  siteName = machine.siteName or hostName;
  # This server as a Tailscale subnet router for the home networks (machine.toml: tailscaleRouter, default false)
  tailscaleRouter = machine.tailscaleRouter;
  # Keyboard layout of the console (machine.toml: keyMap = "de"; no line = the kernel default, US).
  keyMap = machine.keyMap;
  # Time zone (machine.toml: timeZone = "Europe/Vienna"; no line = UTC, the NixOS default).
  timeZone = machine.timeZone;
  # Hourly/daily/weekly ZFS snapshots of every share (machine.toml: shareSnapshots, default false; hs snapshots)
  shareSnapshots = machine.shareSnapshots;
  # hand out numbers for Prometheus (machine.toml: metrics; set by `hs recipe monitoring`)
  metrics = machine.metrics;
  # Optional parts of the server (capabilities/<name>/, docs/PLAN-modular-core.md step 3): the list in machine.toml, plus the
  # parts whose old switch is set (metrics = true; docs = the web interface with webDocs, default on), so a server that was set up before the list existed keeps what it had.
  capabilitiesSetting = machine.capabilities;
  # The role of this node (machine.toml: role). "homeserver" (the default) is what this repo always was: the storage, incus, samba and
  # backup capabilities are on without being named. "edge" (a public VPS) and "minimal" start from the base only.
  role = machine.role;
  isHome = role == "homeserver";
  isEdge = role == "edge";
  roleCapabilities = lib.optionals isHome [ "storage" "incus" "samba" "backup" ];
  # live state (capability live-state): the web reads from Redis; off means direct reads (machine.toml liveState)
  liveOn = webUi && isHome && machine.liveState == "redis";
  # ADR 0026 step 1: the collector writes to state.db (hs-live-db), no Redis
  liveDb = webUi && isHome && machine.liveState == "db";
  capabilities = lib.unique (capabilitiesSetting ++ lib.optional metrics "metrics" ++ lib.optional (tailscaleRouter || webTailscale) "tailscale" ++ lib.optional (ad != null) "ad" ++ lib.optional (webUi && machine.webDocs) "docs" ++ lib.optional liveOn "live-state" ++ roleCapabilities);
  hasStorage = builtins.elem "storage" capabilities;
  hasIncus = builtins.elem "incus" capabilities;
  hasSamba = builtins.elem "samba" capabilities;
  # The admin account (machine.toml: adminUser, chosen at install; default adminuser): SSH, sudo, local web sign-in, owner of the share files
  adminUser = machine.adminUser;
  # what the modules in capabilities/ get as their `hs` argument (the helpers are shared by storage, incus, samba and backup)
  hs = {
    inherit machine adminUser hostName siteName ad bulkSnapraid bulkReady whenUnlocked notifyFailure;
    enabled = name: builtins.elem name capabilities;
    scripts = ./scripts;
  };
  # GRUB for a machine that does not boot from an EFI partition (a VPS); machine.toml: bootDevice
  bootDevice = machine.bootDevice;
  useGrub = bootDevice != "";
  # keys of other nodes that may ask for the status (machine.toml: nodeKeys): only the fixed words of scripts/node-remote.sh
  nodeLines = map (k: ''restrict,command="/etc/nixos/scripts/node-remote.sh" ${k}'') machine.nodeKeys;
  # Read-only status document for a Stream Deck, a wall monitor, Home Assistant (machine.toml: deckApi, default false; hs sys deck)
  deckApi = machine.deckApi;
  # Web interface (machine.toml: webUi, default false; webPort 8480; docs/PLAN-web-backend.md)
  webUi = machine.webUi;
  webPort = machine.webPort;
  # HTTPS through `tailscale serve` (machine.toml: webTailscale, default false): the page then listens on loopback only
  webTailscale = machine.webTailscale;
  # also reachable on the home network by address, plain HTTP (machine.toml: webLan, default true); only with webTailscale does turning it off close the LAN port
  webLan = machine.webLan;
  # Upper limit of the ZFS read cache (ARC) in GiB (machine.toml: zfsArcMaxGB, default 12; 0 = ZFS default, nearly all of the RAM on current OpenZFS)
  zfsArcMaxGB = machine.zfsArcMaxGB;
  # Minutes of idle time after which the spinning bulk/parity/backup disks go to sleep (machine.toml: diskSpindownMinutes, default 0 = never)
  diskSpindownMinutes = machine.diskSpindownMinutes;
  # Graphics chips of this machine (machine.toml: gpu = "nvidia", or ["nvidia", "intel"]).
  # No line: no graphics driver, for a server without a card (or a VM).
  gpuSetting = machine.gpu;
  gpus = if gpuSetting == null then [ ] else if builtins.isList gpuSetting then gpuSetting else [ gpuSetting ];
  hasGpu = g: builtins.elem g gpus;
  # NVIDIA driver branch (machine.toml: nvidiaDriver). "stable" (default) = current driver with the open kernel modules (Turing, RTX 20xx, and newer);
  # "legacy_580" = the last branch that still supports Maxwell, Pascal (GTX 10xx) and Volta, with the closed kernel modules.
  nvidiaDriver = machine.nvidiaDriver;
  # UPS through NUT (machine.toml: ups, a driver string or a table; default off; docs/operations.md, scripts/ups.sh)
  upsSetting = machine.ups;
  upsTable = if upsSetting == null then null else if builtins.isString upsSetting then { driver = upsSetting; } else if upsSetting == true then { } else upsSetting;
  ups = if upsTable == null then null else {
    driver = upsTable.driver or "usbhid-ups";
    name = upsTable.name or "ups";
    port = upsTable.port or "auto";
    shutdownMinutes = upsTable.shutdownMinutes or 5;
    lowBatteryPercent = upsTable.lowBatteryPercent or null;
  };
  # For scheduled jobs: when the job fails, start the unit that sends a message
  # (hs-notify-failure@ below). %N is the name of the failed unit.
  notifyFailure = [ "hs-notify-failure@%N.service" ];
  # While encrypted disks wait for `hs unlock` this file exists (written by
  # hs-unlock below); the services that need the disks don't start then. It
  # never exists on a server without encrypted disks, or when the key file is there.
  whenUnlocked = { ConditionPathExists = "!/run/hs/storage-locked"; };

  # Web interface frontend (pkgs/hs-web.nix); only built when machine.toml says webUi = true
  hsWeb = pkgs.callPackage ./pkgs/hs-web.nix { };

  # The Rust part of the core (pkgs/hobnix.nix): `hobnix`, which registry rows named rust:<subcommand> run (docs/adr/0001-rust-strangler.md)
  hobnix = pkgs.callPackage ./pkgs/hobnix.nix { };

  # The part of the container network the router hands out by DHCP (last number
  # of the address, from - to). An instance with an address in there has no
  # fixed IP yet; hs ct list points that out.
  dhcpRange = machine.dhcpRange;
  # PCI devices (addresses like "0000:05:00.0") that the kernel leaves without a driver at boot; hs-pci-bind attaches them (machine.toml: pciBind).
  pciBind = machine.pciBind;

  # ── VLAN helpers ──
  vlanIf   = v: "vlan${toString v.id}";   # tagged sub-interface, e.g. vlan95
  bridgeOf = name: "br-${name}";          # bridge per VLAN, e.g. br-home

in
{
  imports = [ ./hardware-configuration.nix ] ++ import ./capabilities { inherit lib; inherit (hs) enabled; };
  _module.args.hs = hs;

  # ───────────────────────── Boot ─────────────────────────
  boot.loader.grub = lib.mkIf useGrub { enable = true; device = bootDevice; efiSupport = true; efiInstallAsRemovable = true; };
  boot.loader.systemd-boot.enable = lib.mkIf (!useGrub) true;
  boot.loader.efi.canTouchEfiVariables = lib.mkIf (!useGrub) true;
  # The system disk is small: keep few boot entries, drop old generations weekly.
  boot.loader.systemd-boot.configurationLimit = lib.mkIf (!useGrub) 20;
  # Memory test in the boot menu (non-ECC board: run it after a crash, a new RAM stick or odd ZFS/checksum errors).
  # Get the menu once with `sudo systemctl reboot --boot-loader-menu=30`, pick "Memtest86", let at least one full pass run.
  boot.loader.systemd-boot.memtest86.enable = lib.mkIf (!useGrub) true;
  # No boot menu wait: the default entry starts at once. Hold the space bar while it starts to get the menu (older generations).
  boot.loader.timeout = 0;
  # The second SATA controller (PCI 02:00.0, the 120 GB backup disk is on its port 5 = ata12) reports 32 ports, 26 of them empty; the kernel
  # waits about 0.3 s for each at every boot (about 8 s in the initrd). Keep only ports 0-5 (mask 0x3f). A disk plugged into one of that
  # controller's ports above 5 would not show up: remove this line then (or move the cable to ports 0-5).
  # Console: the screen stays the main console (the last entry: boot messages and the emergency shell go there), the first serial port gets
  # the kernel messages and a login prompt. For a server without a screen (serial over LAN) and for `incus console` of a Hobnix in a VM;
  # a machine without a serial port ignores it. The installer ISO sets the same (installer/iso.nix).
  boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty0" ] ++ lib.optionals isHome [ "ahci.mask_port_map=0000:02:00.0=0x3f" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };
  # Pre-built packages from the project's cache (config/binary-cache.nix). Only an extra source: if it is unreachable or empty, Nix builds locally.
  nix.settings = let c = import ./config/binary-cache.nix; in lib.mkIf (c.name != "" && c.publicKey != "") {
    substituters = [ "https://${c.name}.cachix.org" ];
    trusted-public-keys = [ c.publicKey ];
  };

  boot.supportedFilesystems = lib.optionals hasStorage [ "zfs" "ntfs" "exfat" "cifs" ];   # ntfs/exfat: read disks from Windows (hs disk temp); cifs: shares of other homeservers (hs remote)
  console = lib.mkIf (keyMap != null) { inherit keyMap; };
  time.timeZone = timeZone;

  # ──────────────────────── /bulk on SnapRAID + mergerfs ────────────────────────
  # The scripts read the layout from here (hs pool bulk, create-share, ...).
  environment.etc."hs/bulk-type".text = bulkType;
  environment.etc."hs/share-snapshots".text = if shareSnapshots then "on" else "off";
  environment.etc."hs/incus-ui".text = if incusUi then "on" else "off";
  environment.etc."hs/site-name".text = siteName;
  environment.etc."hs/dhcp-range".text = lib.concatMapStringsSep " " toString dhcpRange;
  environment.etc."hs/capabilities".text = lib.concatStrings (map (c: c + "\n") capabilities);   # scripts/lib/capability.sh


  # ──────────────────────── Networking ────────────────────────
  networking.hostName = hostName;            # also the name Windows shows under "Network"
  networking.hostId = lib.mkIf hasStorage hostId;
  networking.nftables.enable = true;         # required by the Incus module

  networking.useDHCP = if isHome then false else lib.mkDefault true;

  # br0: untagged/native VLAN of the switch port. The host and its web UIs live here.
  # Every VLAN from machine.toml gets a tagged sub-interface (vlanNN) and its own
  # bridge (br-<name>). The host gets no IP on those, so it isn't reachable from them.
  networking.vlans = lib.mkIf isHome (lib.mapAttrs' (name: v:
    lib.nameValuePair (vlanIf v) { id = v.id; interface = nic; }
  ) vlans);

  networking.bridges = lib.mkIf isHome (
    { br0.interfaces = [ nic ]; }
    // lib.mapAttrs' (name: v:
         lib.nameValuePair (bridgeOf name) { interfaces = [ (vlanIf v) ]; }
       ) vlans);

  networking.interfaces = lib.mkIf isHome (
    { br0.useDHCP = true; }
    // lib.mapAttrs' (name: _:
         lib.nameValuePair (bridgeOf name) { useDHCP = false; }
       ) vlans);

  # No ARP probe before the lease address is used: it cost about 4 s at every boot (SSH and the unlock only work once the address
  # exists) and the address is a reservation in the router, so nobody else can hold it.
  networking.dhcpcd.extraConfig = lib.mkIf isHome "noarp";

  # Linux interface names are max. 15 chars, so "br-" + name must fit.
  assertions = lib.optionals isHome (lib.mapAttrsToList (name: _: {
    assertion = builtins.stringLength (bridgeOf name) <= 15;
    message = "machine.toml: VLAN name '${name}' is too long (max. 12 characters).";
  }) vlans) ++ [{
    assertion = !(liveDb && builtins.elem "live-state" capabilities);
    message = "machine.toml: liveState = \"db\" and the capability live-state cannot both be on (two collectors).";
  } {
    # port 22 closed on the network cards and no private interface to reach it on = locked out
    assertion = sshOverIp || config.hs.privateInterfaces != [ ];
    message = "machine.toml: sshOverIp = false closes SSH on the network cards, so something must provide private access (capabilities = [\"tailscale\"]); otherwise nothing can reach this server over SSH.";
  } {
    assertion = builtins.elem syncEveryHours [ 1 2 3 4 6 8 12 24 ];
    message = "machine.toml: syncEveryHours must be 1, 2, 3, 4, 6, 8, 12 or 24 (found ${toString syncEveryHours}).";
  } {
    assertion = builtins.elem bulkType [ "zfs" "snapraid" ];
    message = "machine.toml: bulkType must be \"zfs\" or \"snapraid\" (found \"${bulkType}\").";
  } {
    assertion = lib.all (g: builtins.elem g [ "nvidia" "amd" "intel" ]) gpus;
    message = "machine.toml: gpu must be \"nvidia\", \"amd\", \"intel\" or a list of them (found ${builtins.toJSON gpuSetting}).";
  } {
    assertion = builtins.elem nvidiaDriver [ "stable" "legacy_580" ];
    message = "machine.toml: nvidiaDriver must be \"stable\" or \"legacy_580\" (found ${builtins.toJSON nvidiaDriver}).";
  } {
    assertion = builtins.match "[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?" siteName != null;
    message = "machine.toml: siteName '${siteName}' must be lower case letters, digits and hyphens (it becomes a DNS label).";
  } {
    # NetBIOS limit; Samba would silently truncate a longer name.
    assertion = builtins.stringLength hostName <= 15;
    message = "machine.toml: hostName '${hostName}' is too long (max. 15 characters).";
  }];

  # Bridged traffic (br0, br-home) must not go through the host firewall,
  # otherwise the reverse-path filter drops container/VM packets.
  # The module is loaded explicitly so the sysctl keys exist at boot.
  # uinput: virtual keyboard, mouse and gamepads (the sunshine recipe's container passes them in)
  # nct6775: the board's fan controller (Nuvoton Super I/O), gives pwm*/fan*_input in hwmon
  # ntsync: /dev/ntsync, Wine's kernel thread synchronisation (Windows game servers under Wine, e.g. Enshrouded); idle unless a container opens it
  boot.kernelModules = lib.optionals isHome [ "br_netfilter" "dm_crypt" "nct6775" "uinput" "ntsync" ];
  boot.kernel.sysctl = lib.mkIf isHome {
    "net.bridge.bridge-nf-call-iptables" = 0;
    "net.bridge.bridge-nf-call-ip6tables" = 0;
    "net.bridge.bridge-nf-call-arptables" = 0;
  };

  networking.firewall.allowedTCPPorts = lib.optional (hasIncus && incusUi) 8443;   # Incus web UI
  # Samba ports are opened by its openFirewall option below.

  # Tailscale (the subnet router, `tailscale serve`) is the capability "tailscale": capabilities/tailscale/module.nix.
  # It sets hs.privateInterfaces (capabilities/options.nix); the rules below open a port on those interfaces and do not
  # know which provider they come from.
  # Also holds the status document's port 9740 (deckApi, further down)
  networking.firewall.extraInputRules = let
    onPrivate = port: lib.concatMapStrings (i: ''
      iifname "${i}" tcp dport ${toString port} accept
    '') config.hs.privateInterfaces;
  in lib.concatStrings [
    (lib.optionalString deckApi ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport 9740 accept
    '')
    (lib.optionalString deckApi (onPrivate 9740))
    (lib.optionalString (webUi && webLan) ''
      ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport ${toString webPort} accept
    '')
    (lib.optionalString (webUi && !webTailscale) (onPrivate webPort))
    (lib.optionalString (webUi && webTailscale) (onPrivate 443))
  ];

  # ──────────────────────── Status document (Stream Deck, wall monitor, Home Assistant) ────────────────────────
  # Off unless machine.toml says `deckApi = true`. hs-deck-status writes /run/hs-deck/deck.json every 10 s (as root: it
  # reads disks and pools), hs-deck-api hands out that file (and /disks, /events written next to it) on port 9740, read only, as nobody. Home networks
  # and Tailscale only. Format: scripts/deck-status.sh, test: tests/deck-status.sh
  systemd.services.hs-deck-status = lib.mkIf deckApi {
    description = "Write the status document for displays (hs sys deck)";
    after = lib.optional hasStorage bulkReady;
    path = [ "/run/current-system/sw" ];
    environment.HS_DECK_RECORD = "1";    # this reading goes into the last 24 hours of the document (/var/lib/hs/deck-history)
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /run/hs-deck && chmod 755 /run/hs-deck
      bash ${./scripts}/deck-status.sh > /run/hs-deck/deck.json.new && chmod 644 /run/hs-deck/deck.json.new && mv /run/hs-deck/deck.json.new /run/hs-deck/deck.json
      # the disk inventory and the events from the state database (serials masked); deck-serve.py hands them out at /disks and /events
      for what in disks events; do
        bash ${./scripts}/state.sh $what-json > /run/hs-deck/deck-$what.json.new && chmod 644 /run/hs-deck/deck-$what.json.new && mv /run/hs-deck/deck-$what.json.new /run/hs-deck/deck-$what.json || true
      done
    '';
    startAt = "*:*:0/10";
  };
  systemd.services.hs-deck-api = lib.mkIf deckApi {
    description = "Read-only status endpoint for displays (port 9740)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts}/deck-serve.py 9740 /run/hs-deck/deck.json";
      DynamicUser = true;
      Restart = "on-failure";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
  # (the rule for port 9740 is part of the one extraInputRules above: an attribute cannot be set twice in a file)

  # ──────────────────────── Web interface ────────────────────────
  # Off unless machine.toml says `webUi = true`. ONE process on the HOST (not in Incus: it must work while the storage is locked), as root:
  # it signs people in (Domain Admins through winbind, the local adminuser through unix_chkpwd; only the local one while locked) and
  # will wrap `hs sys ...` for the pages. Plain HTTP on the home networks and Tailscale; NEVER a Zoraxy rule. scripts/web-serve.py, tests/web-login.sh
  systemd.services.hs-web = lib.mkIf webUi {
    description = "Web interface (port ${toString webPort})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ "/run/current-system/sw" config.services.samba.package ];
    environment = {
      HS_CALLER = "web";
      HS_WEB_PORT = toString webPort;
      HS_WEB_ROOT = "${hsWeb}";
      HS_WEB_BIND = if webTailscale && !webLan then "127.0.0.1" else "";
      HS_WEB_SECURE = if webTailscale then "1" else "";
      HS_WEB_TRUST_PROXY = if webTailscale || builtins.elem "gateway" capabilities then "1" else "";
      HS_WEB_WORKGROUP = if ad != null then ad.workgroup else "";
      HS_WEB_REALM = if ad != null then ad.realm else "";
      HS_WEB_LOCAL_USER = adminUser;
      # PrivateTmp gives hs-web its own mount namespace: the unlock (vault mount) must run outside it, in a transient unit
      HS_WEB_UNLOCK_IN_UNIT = "1";
      HS_WEB_SESSION_FILE = "/run/hs-web/sessions.json";
      HS_WEB_LIVE = if builtins.elem "live-state" capabilities then "redis" else if liveDb then "db" else "";
    };
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts}/web-serve.py";
      Restart = "on-failure";
      PrivateTmp = true;
      NoNewPrivileges = true;
      # /run/hs-web/sessions.json: hashes of the session cookies, so a restart (hs update) does not sign everybody out; a reboot clears /run
      RuntimeDirectory = "hs-web";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      # the Redis socket of the live state (capability live-state); hs-web still starts without Redis and answers 503
      SupplementaryGroups = lib.optionals (builtins.elem "live-state" capabilities) [ "hs-live" "redis-hobnix" ];
    };
  };

  # HTTPS for the web interface through `tailscale serve` (webTailscale): the unit hs-web-tailscale is in capabilities/tailscale/module.nix.

  # ──────────────────────── Access ────────────────────────
  # machine.toml: sshOverIp (default true). Off: port 22 is closed on the network cards, SSH only on the private interfaces
  # (hs.privateInterfaces, set by the capability that provides private-access: tailscale).
  networking.firewall.interfaces = lib.genAttrs config.hs.privateInterfaces (_: { allowedTCPPorts = lib.optional (!sshOverIp) 22 ++ lib.optional isEdge 2222; });
  services.openssh = {
    enable = true;
    openFirewall = sshOverIp;
    # an edge node also listens on 2222: `hs node` (kind vps) logs in as root there with the forced-command key of nodeKeys
    ports = lib.mkIf isEdge [ 22 2222 ];
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = if isEdge then "forced-commands-only" else "no";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = lib.mkIf (isEdge && nodeLines != [ ]) nodeLines;

  users.users.${adminUser} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ] ++ lib.optional hasIncus "incus-admin";
    openssh.authorizedKeys.keys = sshKeys ++ lib.optionals (!isEdge) nodeLines;
  };




  # The admin account name for scripts (scripts/lib/admin.sh: admin_user)
  environment.etc."hs/admin-user".text = adminUser;

  # Share directory owned by the admin user so it's writable over Samba
  # (on the snapraid layout bulk-mount.sh does this after merging the disks).
  # "z": only adjust it where it exists. Creating it ("d") made /bulk/shares on
  # the system disk while there was no pool yet, and `zpool create` then
  # refused the non-empty /bulk.
  systemd.tmpfiles.rules =
    lib.optional (hasStorage && !bulkSnapraid) "z /bulk/shares 2775 ${adminUser} users -"
    # where hs health leaves its numbers for node-exporter
    # the live ARC limit (zfsArcMaxGB), see boot.extraModprobeConfig above
    ++ lib.optional (hasStorage && zfsArcMaxGB > 0) "w /sys/module/zfs/parameters/zfs_arc_max - - - - ${toString (zfsArcMaxGB * 1073741824)}"
    ++ [
      # Without a ~/.zshrc zsh starts a setup wizard on the first login.
      "f /home/${adminUser}/.zshrc 0644 ${adminUser} users -"
      "f /root/.zshrc 0644 root root -"
      # micro copies through the terminal (OSC 52): over SSH there is no X server for
      # xclip. Written only when the file doesn't exist, so own settings are kept.
      "d /home/${adminUser}/.config 0700 ${adminUser} users -"
      "d /home/${adminUser}/.config/micro 0755 ${adminUser} users -"
      "f /home/${adminUser}/.config/micro/settings.json 0644 ${adminUser} users - {\"clipboard\":\"terminal\"}"
    ];


  # "Server started" (only when the vault is open: otherwise hs-unlock-alarm is the message) and "going down" (low priority, reboot or shutdown).
  systemd.services.hs-boot-notice = {
    description = "Push message: the server started";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "hs-unlock.service" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${./scripts}/power-notice.sh started";
  };
  # Brings back what a person started with an extension (a `sys ext <name> boot` row, docs/PLAN-extensions.md "At boot"); one static unit, no rebuild per package.
  systemd.services.hs-ext-boot = {
    description = "Start the services of the extensions that are on (hs ext boot)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ] ++ lib.optional hasIncus "incus.service";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${./scripts}/ext.sh boot";
  };
  systemd.services.hs-shutdown-notice = {
    description = "Push message: the server is going down";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = "/run/current-system/sw/bin/bash ${./scripts}/power-notice.sh stopping";
      TimeoutStopSec = 20;
    };
  };

  # ──────────────────────── Graphics (machine.toml: gpu) ────────────────────────
  # The driver runs on the host; the GPU is shared with Incus containers.
  # (Not VFIO passthrough: that would hand the card exclusively to one VM.)
  # "nvidia": proprietary-stack open modules + the container toolkit. "amd" and "intel":
  # the kernel drivers (amdgpu, i915) do the work, containers bring their own Mesa/VAAPI.
  # No line in machine.toml: nothing is installed.
  services.xserver.videoDrivers = lib.mkIf (gpus != [ ])    # loads the driver; no X server is started
    (lib.optional (hasGpu "nvidia") "nvidia"
     ++ lib.optional (hasGpu "amd") "amdgpu"
     ++ lib.optional (hasGpu "intel") "modesetting");
  hardware.graphics.enable = lib.mkIf (gpus != [ ]) true;
  hardware.nvidia = lib.mkIf (hasGpu "nvidia") {
    open = nvidiaDriver == "stable";   # open kernel modules, recommended for Turing and newer (RTX 20xx up); Pascal and older need the closed ones (legacy_580)
    nvidiaSettings = false;        # headless, no settings GUI
    package = config.boot.kernelPackages.nvidiaPackages.${nvidiaDriver};
  };
  # Generates the CDI spec (nvidia.com/gpu=...) that Incus uses to pass the GPU into containers
  hardware.nvidia-container-toolkit.enable = hasGpu "nvidia";

  # RAM temperature sensors (jc42): the BIOS leaves the thresholds at 0 °C,
  # which triggers a permanent false alarm. Set sensible DDR4 values (millidegrees).
  services.udev.extraRules = lib.optionalString isHome (''
    ACTION=="add", SUBSYSTEM=="hwmon", ATTR{name}=="jc42", ATTR{temp1_max}="85000", ATTR{temp1_crit}="95000"
    # A disk appears or goes away: hs-disk-event@ logs it and sends a push message (it never touches the disk).
    # udev only starts the unit (no waiting, no work inside udev). The instance is "<action>-<kernel name>".
    # Virtual input devices (made through /dev/uinput, e.g. by Sunshine in its container): the container's user must open them.
    SUBSYSTEM=="input", KERNEL=="event*", DEVPATH=="/devices/virtual/input/*", MODE="0666"
    ACTION=="add|remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL!="loop*|ram*|zram*|sr*|dm-*|md*|nbd*|zd*|fd*", RUN+="${pkgs.systemd}/bin/systemctl --no-block start hs-disk-event@%E{ACTION}-%k.service"
  '' + lib.optionalString (diskSpindownMinutes > 0) ''
    # A disk appears: apply the standby timer (hs-disk-spindown, only when diskSpindownMinutes > 0)
    ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL!="loop*|ram*|zram*|sr*|dm-*|md*|nbd*|zd*|fd*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hs-disk-spindown.service"
  '');

  # ──────────────────────── Packages ────────────────────────
  # Needed for the NVIDIA driver
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    hobnix          # the Rust part of the core (pkgs/hobnix.nix)
    vim
    git
    htop
    tmux            # the web terminal keeps its shell in a tmux session (scripts/web_terminal.py)
    wget
  ] ++ lib.optionals hasStorage (with pkgs; [
    smartmontools   # smartctl for disk health
    hdparm          # standby timer of the spinning disks (scripts/disk-spindown.sh)
    attr            # setfattr: add a disk to the merged /bulk without unmounting
  ]) ++ (with pkgs; [
    eza             # ls with colours and git state (aliases ll, la, tree)
    bat             # cat with syntax colouring
    mc              # Midnight Commander: file manager, plus mcedit (editor) and mcview
    micro           # simple terminal editor with normal keys (Ctrl+S, Ctrl+Q); not part of mc

    # curl, and whiptail (newt) for the installer dialogs of manage-pool.sh --plain
    curl
    newt            # provides whiptail for the installer dialogs
    gum             # spinners and the chooser of `hs recipe`
    jq
    (python3.withPackages (ps: [ ps.pillow ]))   # python3 for the scripts (state database: stdlib only) plus Pillow for `hs generate poster`
    rsync          # hs disk temp copy, snapraid cache mover
  ]) ++ lib.optionals hasStorage (with pkgs; [
    restic          # hs backup
    cryptsetup      # encrypted disks (hs unlock, hs pool bulk add --encrypt)
  ]) ++ (with pkgs; [
    openssl         # hs dc cert: the CA and the checks of the signed certificates
  ]) ++ lib.optionals hasStorage (with pkgs; [
    fuse3           # hs backup browse (restic mount)
    xfsprogs        # hs pool bulk add --role adopt writes the label of xfs disks
    btrfs-progs     # ... and of btrfs disks
    testdisk        # photorec: hs disk <member> recover searches a data disk for deleted files (scripts/disk-recover.sh)
    ffmpeg-headless # ffprobe: names the recovered videos and music by their tags
  ]) ++ (with pkgs; [

    # `hs <command>` runs scripts/<command>.sh from this repo; the definition is shared with install.nix (hs-command.nix).
    (import ./hs-command.nix { inherit pkgs; })
  ])
  # tools of the snapraid layout
  ++ lib.optionals (hasStorage && bulkSnapraid) [ pkgs.mergerfs pkgs.snapraid ]
  ++ lib.optionals isEdge [ pkgs.tcpdump ];



  # ──────────────────────── UPS (machine.toml: ups) ────────────────────────
  # NUT in standalone mode: the driver talks to the UPS, upsd (127.0.0.1 only) hands the values out,
  # upsmon shuts the server down cleanly on a low battery and calls scripts/ups.sh event for the push
  # messages and the "N minutes on battery" countdown. The password only protects a loopback service.
  power.ups = lib.mkIf (ups != null) {
    enable = true;
    mode = "standalone";
    ups.${ups.name} = {
      driver = ups.driver;
      port = ups.port;
      description = "UPS of ${hostName}";
      directives = lib.optional (ups.lowBatteryPercent != null) "override.battery.charge.low = ${toString ups.lowBatteryPercent}";
    };
    users.upsmon = {
      passwordFile = toString (pkgs.writeText "hs-ups-password" "hs-ups-local");
      upsmon = "primary";
    };
    upsmon.monitor.${ups.name} = {
      system = "${ups.name}@localhost";
      user = "upsmon";
      passwordFile = toString (pkgs.writeText "hs-ups-password" "hs-ups-local");
      type = "primary";
    };
    upsmon.settings = {
      MINSUPPLIES = 1;
      NOTIFYCMD = "${pkgs.bash}/bin/bash ${./scripts}/ups.sh event";
      NOTIFYFLAG = map (e: [ e "SYSLOG+EXEC" ]) [ "ONLINE" "ONBATT" "LOWBATT" "FSD" "COMMOK" "COMMBAD" "SHUTDOWN" "REPLBATT" ];
    };
  };
  environment.etc."hs/ups" = lib.mkIf (ups != null) {
    text = "name=${ups.name}\nshutdownMinutes=${toString ups.shutdownMinutes}\n";
  };

  # ──────────────────────── Notifications ────────────────────────

  # Looks at pools, disks, free space, failed jobs and the domain controller's
  # certificate. Sends one message when the list of problems changes, and an
  # "all clear" when it is empty again. By hand: hs health
  systemd.services.hs-health-check = {
    description = "Check storage and scheduled jobs, push a message on problems (hs health)";
    after = lib.optional hasStorage bulkReady ++ lib.optional hasIncus "incus.service";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    # an edge node has no pools or containers: its own checks (scripts/edge-health.sh)
    script = "bash ${./scripts}/${if isEdge then "edge-health.sh" else "health-check.sh"}";
    startAt = "*:0/15";
    onFailure = notifyFailure;
  };


  # The slow reads of the web interface (scripts/lib/collected-reads.tsv) are kept in the state database, so a page opens without waiting for the
  # scripts (scripts/reads-collect.sh, scripts/web-serve.py). Only with the web interface; every 15 s, it reads what is older than its own interval.
  # If it stops, the web interface starts the scripts itself again. Nothing runs while the storage is locked (the script checks).
  systemd.services.hs-reads-collect = lib.mkIf webUi {
    description = "Keep the slow reads of the web interface in the state database (hs sys reads collect)";
    path = [ "/run/current-system/sw" pkgs.python3 ];
    serviceConfig.Type = "oneshot";
    script = "bash ${./scripts}/reads-collect.sh";
    onFailure = notifyFailure;
  };
  systemd.timers.hs-reads-collect = lib.mkIf webUi {
    description = "Timer of hs-reads-collect";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitInactiveSec = "15s"; AccuracySec = "1s"; };
  };

  # ADR 0026 step 1 (liveState = "db", off by default): the live-state collector without Redis; it writes the topics and one heartbeat row into
  # state.db (scripts/live-collect.py, HS_LIVE_STORE=db). Only for the measurement (hs live measure). Not tested on hardware yet.
  systemd.services.hs-live-db = lib.mkIf liveDb {
    description = "Live state collector into the state database (ADR 0026 step 1)";
    wantedBy = [ "multi-user.target" ];
    path = [ "/run/current-system/sw" pkgs.python3 ];
    environment = { HS_CALLER = "ui"; HS_LIVE_STORE = "db"; };
    serviceConfig = { ExecStart = "${pkgs.python3}/bin/python3 ${./scripts}/live-collect.py"; Restart = "always"; RestartSec = 5; };
    onFailure = notifyFailure;
  };

  # Notifications are a subscriber of the event log (docs/adr/0005-events.md, docs/notify-rules.md): this reads the rows after its cursor,
  # matches them with scripts/lib/notify-rules.tsv and calls `hs notify`; it also takes in the events the media helpers in containers
  # leave in the share `media`. One cheap read per run. Not on an edge node (no event log there).
  systemd.services.hs-event-notify = lib.mkIf (!isEdge) {
    description = "Send the push messages that the event log asks for (scripts/event-notify.sh)";
    path = [ "/run/current-system/sw" pkgs.python3 ];
    serviceConfig.Type = "oneshot";
    script = "bash ${./scripts}/event-notify.sh";
  };
  systemd.timers.hs-event-notify = lib.mkIf (!isEdge) {
    description = "Timer of hs-event-notify";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitInactiveSec = "30s"; AccuracySec = "1s"; };
  };






  # Old system generations pile up and fill the root disk. Weekly: delete the ones older than
  # 30 days (the newer ones stay for `hs system rollback`).
  systemd.services.hs-system-gc = {
    description = "Delete system generations older than 30 days (hs system gc)";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = "bash ${./scripts}/system.sh gc 30 --yes";
    startAt = "Sun 06:30";
    onFailure = notifyFailure;
  };

  # After a restart, job records (ADR 0004) still queued or running whose unit is gone are marked
  # interrupted and one push says so. Nothing is started again (scripts/job-reconcile.sh, #133).
  systemd.services.hs-job-reconcile = {
    description = "Mark jobs that a restart interrupted in the job record, push one message";
    wantedBy = [ "multi-user.target" ];
    before = [ "hs-web.service" ];   # the web interface then never shows a dead job as running
    path = [ "/run/current-system/sw" pkgs.python3 ];
    serviceConfig.Type = "oneshot";
    script = "bash ${./scripts}/job-reconcile.sh";
  };

  # Started by `onFailure` of the jobs above, e.g. hs-notify-failure@hs-mac.service
  # after hs-mac failed. %i is the part after the @: the name of the failed job.
  systemd.services."hs-notify-failure@" = {
    description = "Push a message: %i failed";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    scriptArgs = "%i";
    script = ''
      bash ${./scripts}/notify.sh --category problem "$(hostname): $1 failed" \
        "The scheduled job $1 failed. Details: journalctl -u $1" high
    '';
  };


  # ──────────────────────── Shell ────────────────────────
  # What you see after `ssh`: zsh with suggestions from the history, syntax
  # colouring and fuzzy search (Ctrl+R history, Ctrl+T files), and a prompt that
  # shows host, folder, git state and how long a command took. zsh runs the
  # commands from the guides unchanged; the `hs` scripts keep using bash.
  # Colours are Catppuccin Mocha, the palette of the `hs` interfaces.
  programs.zsh = {
    enable = true;
    autosuggestions.enable = true;      # grey suggestion while typing, → accepts it
    syntaxHighlighting.enable = true;   # unknown commands turn red before Enter
    histSize = 20000;
    setOptions = [
      "HIST_IGNORE_ALL_DUPS"   # one entry per command
      "HIST_IGNORE_SPACE"      # a leading space keeps a command out of the history
      "SHARE_HISTORY"          # all open sessions see the same history
      "INTERACTIVE_COMMENTS"   # pasted lines with # comments work
    ];
    interactiveShellInit = ''
      bindkey -e                              # Ctrl+A / Ctrl+E etc., as in bash
      bindkey '^[[1;5C' forward-word          # Ctrl+Right
      bindkey '^[[1;5D' backward-word         # Ctrl+Left
      bindkey '^[[H' beginning-of-line        # Home
      bindkey '^[[F' end-of-line              # End
      bindkey '^[[3~' delete-char             # Delete
      zstyle ':completion:*' menu select      # Tab opens a list to move through
      zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'   # case-insensitive
      # `hs <Tab>`: the words come from scripts/lib/registry.tsv (hs sys complete)
      _hs() { local -a c; c=("''${(@f)$(hs sys complete "''${(@)words[2,CURRENT-1]}" 2>/dev/null)}"); compadd -a c; }
      compdef _hs hs
      # three status lines at SSH login (switch off: hs config set loginMessage false)
      if [[ -o login && -n "$SSH_TTY" && -z "$HS_MOTD_DONE" ]]; then export HS_MOTD_DONE=1; hs motd 2>/dev/null; fi
    '';
  };
  users.defaultUserShell = pkgs.zsh;   # ~/.zshrc is created empty by the tmpfiles rules above

  programs.bash.interactiveShellInit = ''
    _hs() { COMPREPLY=($(compgen -W "$(hs sys complete "''${COMP_WORDS[@]:1:COMP_CWORD-1}" 2>/dev/null)" -- "''${COMP_WORDS[COMP_CWORD]}")); }
    complete -F _hs hs
    if shopt -q login_shell && [ -n "$SSH_TTY" ] && [ -z "$HS_MOTD_DONE" ]; then export HS_MOTD_DONE=1; hs motd 2>/dev/null; fi
  '';

  programs.fzf = {
    keybindings = true;
    fuzzyCompletion = true;
  };

  programs.starship = {
    enable = true;
    settings = {
      palette = "catppuccin_mocha";
      palettes.catppuccin_mocha = {
        green = "#a6e3a1"; yellow = "#f9e2af"; peach = "#fab387"; red = "#f38ba8";
        blue = "#89b4fa"; mauve = "#cba6f7"; sky = "#89dceb"; teal = "#94e2d5";
        text = "#cdd6f4"; subtext = "#a6adc8"; overlay = "#6c7086";
      };
      add_newline = true;
      # Plain symbols only: works with any font, also in the Incus web console.
      format = "$username$hostname$directory$git_branch$git_status$nix_shell$cmd_duration$line_break$character";
      username = { format = "[$user]($style) "; style_user = "peach"; style_root = "bold red"; };
      hostname = { ssh_only = false; format = "[$hostname]($style) "; style = "bold mauve"; };
      directory = { style = "bold blue"; truncation_length = 4; truncate_to_repo = false; };
      git_branch = { format = "[$symbol$branch]($style) "; symbol = "git:"; style = "sky"; };
      git_status = { format = "([$all_status$ahead_behind]($style) )"; style = "yellow"; };
      nix_shell = { format = "[nix-shell]($style) "; style = "teal"; };
      cmd_duration = { min_time = 3000; format = "[took $duration]($style) "; style = "overlay"; };
      character = { success_symbol = "[>](bold green)"; error_symbol = "[>](bold red)"; };
      # Right-hand stats, a snapshot taken when the prompt is drawn (not live; hs monitor is).
      # Kept to cheap commands: each custom module forks once per prompt, so no zpool/df on pools.
      right_format = "$memory_usage$custom";
      memory_usage = {
        disabled = false;
        threshold = -1;   # always show
        symbol = "";
        format = "[ram $ram_pct]($style) |";
        style = "subtext";
      };
      custom.load = {
        command = "cut -d' ' -f1 /proc/loadavg";
        when = "true";
        format = "[load $output]($style) |";
        style = "subtext";
      };
      custom.disk = {
        command = "df --output=pcent / | tail -n1 | tr -d ' '";
        when = "true";
        format = "[os $output]($style) |";
        style = "subtext";
      };
    };
  };

  environment.variables = {
    BAT_THEME = "Catppuccin Mocha";
    # fzf in the same colours
    FZF_DEFAULT_OPTS = "--color=bg+:#313244,spinner:#f5e0dc,hl:#f38ba8,fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc,marker:#a6e3a1,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8";
  };

  # Lets the server understand every common terminal program you connect
  # from (Ghostty, Kitty, WezTerm, ...); without it keys like Backspace or
  # full-screen programs misbehave over SSH.
  environment.enableAllTerminfo = true;

  # Shortcuts for the shell
  environment.shellAliases = {
    rebuild = "hs rebuild";
    ll      = "eza -l --group-directories-first --git";
    la      = "eza -la --group-directories-first --git";
    tree    = "eza --tree --level=2";
  };

  system.stateVersion = "26.05";
}
