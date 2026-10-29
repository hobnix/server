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
  # Logins and groups then come from the domain. Without it, adminuser is the
  # only Samba login (password: sudo smbpasswd -a adminuser).
  ad = machine.adDomain;
  # How /bulk is built. "zfs": a pool like fast (mirror pairs). "snapraid":
  # single disks of any size, merged with mergerfs, protected by SnapRAID parity.
  bulkType = machine.bulkType;
  # Language of the descriptions and messages of the hs commands: "en" (default) or "de".
  # Commands, options and file names are never translated. See scripts/lib/i18n.sh.
  language = machine.language;
  bulkSnapraid = bulkType == "snapraid";
  # what has to be up before anything touches /bulk
  bulkReady = if bulkSnapraid then "bulk-mount.service" else "zfs-mount.service";
  # Optional address push messages are POSTed to (ntfy.sh style); see `hs notify`.
  notifyUrl = machine.notifyUrl;
  # address that gets a "still alive" message every health check (machine.toml: heartbeatUrl); scripts/vps-watch.sh on the VPS raises the alarm when it stops
  heartbeatUrl = machine.heartbeatUrl;
  # Does a share (or dataset) that appears later go into the backup by itself? (machine.toml:
  # backupNewShares, default false: a share is only backed up once you switch it on)
  backupNewShares = machine.backupNewShares;
  # Hours between two parity syncs (machine.toml: syncEveryHours, default 24 = once a night at 03:00, so the HDDs can sleep
  # the rest of the day; 4 = 03 07 11 15 19 23).
  syncEveryHours = machine.syncEveryHours;
  # Incus web UI and the network address of the Incus API (machine.toml: incusUi, default true)
  incusUi = machine.incusUi;
  sshOverIp = machine.sshOverIp;
  # The label in front of the domain for this server's DNS names, <instance>.<siteName>.<domain> (machine.toml: siteName, default hostName; hs dns)
  siteName = machine.siteName or hostName;
  # This server as a Tailscale subnet router for the home networks (machine.toml: tailscaleRouter, default false)
  tailscaleRouter = machine.tailscaleRouter;
  # Keyboard layout of the console (machine.toml: keyMap = "de"; no line = the kernel default, US).
  keyMap = machine.keyMap;
  # Time zone (machine.toml: timeZone = "Europe/Vienna"; no line = UTC, the NixOS default).
  timeZone = machine.timeZone;
  # Hourly/daily/weekly ZFS snapshots of every share (machine.toml: shareSnapshots, default false; hs snapshots)
  shareSnapshots = machine.shareSnapshots;
  # Three status lines at SSH login (machine.toml: loginMessage, default true; hs motd)
  loginMessage = machine.loginMessage;
  # Icons of the interface and the console (machine.toml: icons = "unicode" | "nerd" | "ascii"; nerd needs a Nerd Font in your terminal)
  icons = machine.icons;
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
  capabilities = lib.unique (capabilitiesSetting ++ lib.optional metrics "metrics" ++ lib.optional (tailscaleRouter || webTailscale) "tailscale" ++ lib.optional (ad != null) "ad" ++ lib.optional (webUi && machine.webDocs) "docs" ++ roleCapabilities);
  hasStorage = builtins.elem "storage" capabilities;
  hasIncus = builtins.elem "incus" capabilities;
  hasSamba = builtins.elem "samba" capabilities;
  # what the modules in capabilities/ get as their `hs` argument (the helpers are shared by storage, incus, samba and backup)
  hs = {
    inherit machine hostName siteName ad bulkSnapraid bulkReady whenUnlocked notifyFailure;
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
  # Web interface (machine.toml: webUi, default false; webPort 8480; webAccent "#9184d9"; docs/PLAN-web-backend.md)
  webUi = machine.webUi;
  webPort = machine.webPort;
  webAccent = machine.webAccent;
  # HTTPS through `tailscale serve` (machine.toml: webTailscale, default false): the page then listens on loopback only
  webTailscale = machine.webTailscale;
  # also reachable on the home network by address, plain HTTP (machine.toml: webLan, default true); only with webTailscale does turning it off close the LAN port
  webLan = machine.webLan;
  # a terminal in the web interface (machine.toml: webTerminal, default false): HS_WEB_TERMINAL for hs-web, shell runs as adminuser
  webTerminal = machine.webTerminal;
  # how long a browser terminal connection may idle (minutes) / last (hours); the shell stays in tmux either way
  webTerminalIdleMinutes = machine.webTerminalIdleMinutes;
  webTerminalMaxHours = machine.webTerminalMaxHours;
  # Status document of the proxyserver for the web interface (machine.toml: proxyStatusUrl, default "" = off)
  proxyStatusUrl = machine.proxyStatusUrl;
  # Where the web interface runs `vps update` / `vps watch` over SSH (machine.toml: vpsHost, default "" = off); the work is scripts/vps-change.sh
  vpsHost = machine.vpsHost;
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
  boot.kernelParams = lib.optionals isHome [ "ahci.mask_port_map=0000:02:00.0=0x3f" ];
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };

  boot.supportedFilesystems = lib.optionals hasStorage [ "zfs" "ntfs" "exfat" "cifs" ];   # ntfs/exfat: read disks from Windows (hs disk temp); cifs: shares of other homeservers (hs remote)
  console = lib.mkIf (keyMap != null) { inherit keyMap; };
  time.timeZone = timeZone;

  # ──────────────────────── /bulk on SnapRAID + mergerfs ────────────────────────
  # The scripts read the layout from here (hs pool bulk, create-share, ...).
  environment.etc."hs/bulk-type".text = bulkType;
  environment.etc."hs/share-snapshots".text = if shareSnapshots then "on" else "off";
  environment.etc."hs/login-message".text = if loginMessage then "on" else "off";
  environment.etc."hs/icons".text = icons;
  environment.etc."hs/incus-ui".text = if incusUi then "on" else "off";
  environment.etc."hs/backup-new-shares".text = if backupNewShares then "on" else "off";
  environment.etc."hs/language".text = language;
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
    # port 22 closed on the network cards and no private interface to reach it on = locked out
    assertion = sshOverIp || config.hs.privateInterfaces != [ ];
    message = "machine.toml: sshOverIp = false closes SSH on the network cards, so something must provide private access (capabilities = [\"tailscale\"]); otherwise nothing can reach this server over SSH.";
  } {
    assertion = builtins.elem syncEveryHours [ 1 2 3 4 6 8 12 24 ];
    message = "machine.toml: syncEveryHours must be 1, 2, 3, 4, 6, 8, 12 or 24 (found ${toString syncEveryHours}).";
  } {
    assertion = builtins.match "#[0-9a-fA-F]{6}" webAccent != null;
    message = "machine.toml: webAccent must be a colour like \"#9184d9\" (found \"${webAccent}\").";
  } {
    assertion = proxyStatusUrl == "" || builtins.match "https?://[^ ]+" proxyStatusUrl != null;
    message = "machine.toml: proxyStatusUrl must be empty or start with http:// or https:// (found \"${proxyStatusUrl}\").";
  } {
    assertion = vpsHost == "" || builtins.match "[A-Za-z0-9][A-Za-z0-9._:-]{0,100}" vpsHost != null;
    message = "machine.toml: vpsHost must be a host name or address (found \"${vpsHost}\").";
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
    assertion = builtins.elem language [ "en" "de" ];
    message = "machine.toml: language must be \"en\" or \"de\" (found \"${language}\").";
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
      HS_WEB_ACCENT = webAccent;
      HS_WEB_PROXY_URL = proxyStatusUrl;
      HS_WEB_VPS_HOST = vpsHost;
      HS_WEB_BIND = if webTailscale && !webLan then "127.0.0.1" else "";
      HS_WEB_SECURE = if webTailscale then "1" else "";
      HS_WEB_TRUST_PROXY = if webTailscale || builtins.elem "gateway" capabilities then "1" else "";
      HS_WEB_WORKGROUP = if ad != null then ad.workgroup else "";
      HS_WEB_REALM = if ad != null then ad.realm else "";
      HS_WEB_LOCAL_USER = "adminuser";
      HS_WEB_TERMINAL = if webTerminal then "1" else "";
      HS_WEB_TERM_IDLE_MINUTES = toString webTerminalIdleMinutes;
      HS_WEB_TERM_MAX_HOURS = toString webTerminalMaxHours;
      # PrivateTmp gives hs-web its own mount namespace: the unlock (vault mount) must run outside it, in a transient unit
      HS_WEB_UNLOCK_IN_UNIT = "1";
      HS_WEB_SESSION_FILE = "/run/hs-web/sessions.json";
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

  users.users.adminuser = {
    isNormalUser = true;
    extraGroups = [ "wheel" ] ++ lib.optional hasIncus "incus-admin";
    openssh.authorizedKeys.keys = sshKeys ++ lib.optionals (!isEdge) nodeLines;
  };




  # Share directory owned by adminuser so it's writable over Samba
  # (on the snapraid layout bulk-mount.sh does this after merging the disks).
  # "z": only adjust it where it exists. Creating it ("d") made /bulk/shares on
  # the system disk while there was no pool yet, and `zpool create` then
  # refused the non-empty /bulk.
  systemd.tmpfiles.rules =
    lib.optional (hasStorage && !bulkSnapraid) "z /bulk/shares 2775 adminuser users -"
    # where hs health leaves its numbers for node-exporter
    # the live ARC limit (zfsArcMaxGB), see boot.extraModprobeConfig above
    ++ lib.optional (hasStorage && zfsArcMaxGB > 0) "w /sys/module/zfs/parameters/zfs_arc_max - - - - ${toString (zfsArcMaxGB * 1073741824)}"
    ++ [
      # Without a ~/.zshrc zsh starts a setup wizard on the first login.
      "f /home/adminuser/.zshrc 0644 adminuser users -"
      "f /root/.zshrc 0644 root root -"
      # micro copies through the terminal (OSC 52): over SSH there is no X server for
      # xclip. Written only when the file doesn't exist, so own settings are kept.
      "d /home/adminuser/.config 0700 adminuser users -"
      "d /home/adminuser/.config/micro 0755 adminuser users -"
      "f /home/adminuser/.config/micro/settings.json 0644 adminuser users - {\"clipboard\":\"terminal\"}"
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

    # `hs <command>` runs scripts/<command>.sh from this repo (copied into
    # the Nix store on every rebuild). `hs help` lists all commands, plain
    # `hs` shows the same list.
    (writeShellScriptBin "hs" ''
      set -euo pipefail
      dir=${./scripts}
      # Everything else is scripts/lib/hs.sh (registry.tsv: names, groups, help,
      # completion). Help, the registry and completion only read files and run
      # as the caller; every other command needs root (Incus, ZFS, NixOS).
      # sudo drops the environment, so pass var_* (overrides of a recipe or installer), the
      # language and the caller marker through.
      case "''${1:-help}" in
        help|-h|--help) exec bash "$dir/lib/hs.sh" "$@" ;;
        motd) shift; exec bash "$dir/motd.sh" "$@" ;;   # reads state files only: no root
        sys) case "''${2:-}" in registry|complete|motd) exec bash "$dir/lib/hs.sh" "$@" ;; esac ;;   # read-only forms: no root
      esac
      if [ "$(id -u)" -ne 0 ]; then
        mapfile -t vars < <(env | grep -E '^(var_[A-Za-z0-9_]+|HS_LANG|HS_CALLER)=' || true)
        exec sudo env "''${vars[@]}" "$0" "$@"
      fi
      exec bash "$dir/lib/hs.sh" "$@"
    '')
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
  # Where push messages go (machine.toml: notifyUrl). Without it `hs notify`
  # only writes to the journal: journalctl -t hs-notify
  environment.etc."hs/notify-url" = lib.mkIf (notifyUrl != null) { text = notifyUrl; };
  environment.etc."hs/heartbeat-url" = lib.mkIf (heartbeatUrl != null) { text = heartbeatUrl; };

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
      # three status lines at SSH login (switch off: loginMessage = false in machine.toml)
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
