{ config, lib, pkgs, hs, ... }:

let
  inherit (hs) machine bulkReady whenUnlocked notifyFailure ad;
  scripts = hs.scripts;
  smbAllow = machine.smbAllow;
  # Who may open the two catch-all shares. In a domain that's the admins only:
  # everyone else gets per-dataset shares with their own permissions.
  smbValid =
    if ad != null
    then ''adminuser @"${ad.workgroup}\Domain Admins"''
    else "adminuser";
in
{
  # ──────────────────────── Samba ────────────────────────
  services.samba = {
    enable = true;
    openFirewall = true;
    # The default build has no Active Directory support
    package = lib.mkIf (ad != null) pkgs.samba4Full;
    settings = {
      global = {
        "workgroup" = if ad != null then ad.workgroup else "WORKGROUP";
        "server string" = "NixOS NAS";
        "security" = if ad != null then "ads" else "user";
        "map to guest" = "bad user";
        "hosts allow" = smbAllow;
        # Per-dataset shares (`hs share add`, `hs share repair`) are stored in
        # Samba's registry; their per-user access is set from Windows (fsmgmt.msc).
        "include" = "registry";
        # The network list shows a share only to people whose share ACL gives them at least read
        # access, so a group or user set to "none" in the share's permissions does not see it.
        # (`browseable = no` still hides it for everybody.)
        "access based share enum" = "yes";
      } // lib.optionalAttrs (ad != null) {
        # Domain member: join once with `net ads join -U Administrator`.
        "realm" = ad.realm;
        "kerberos method" = "secrets and keytab";
        "winbind refresh tickets" = "yes";
        # Domain users get stable Unix ids derived from their RID; they never
        # log in to the server itself.
        "idmap config * : backend" = "tdb";
        "idmap config * : range" = "3000-7999";
        "idmap config ${ad.workgroup} : backend" = "rid";
        "idmap config ${ad.workgroup} : range" = "10000-999999";
        "template shell" = "/run/current-system/sw/bin/nologin";
      };

      shares = {
        "path" = "/bulk/shares";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "valid users" = smbValid;
        # Whoever logs in, files are written as adminuser on disk, so
        # ownership never gets mixed up. Who gets in is decided per share.
        "force user" = "adminuser";
      };

      # Container-owned data (backups, app state): one dataset per folder,
      # created with `hs share add <name> --sensitive`. Containers write
      # there as their own users (often root, 0700), so it's read as root;
      # read-only for every Samba user, so Windows can't alter what they manage.
      # The fast pool is deliberately not shared (Incus-managed).
      sensitive = {
        "path" = "/bulk/sensitive";
        "browseable" = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = smbValid;
        "force user" = "root";
      };
    };
  };

  # Domain users and groups must be resolvable on the host, otherwise Samba
  # can't map a login to a Unix account.
  system.nssModules = lib.mkIf (ad != null) [ config.services.samba.package ];
  system.nssDatabases = lib.mkIf (ad != null) {
    # Samba needs winbind here (smbd maps a domain login with getpwuid), so it stays. But a
    # name found in /etc must not go on to ask winbind: `getent initgroups adminuser` (what
    # sshd does at every login) otherwise waited 5 s whenever winbind's cache had run out
    # (journalctl -t hs-nss-warm, 2026-10-08). Only names that are not local reach winbind.
    passwd = lib.mkForce [ "files [SUCCESS=return]" "winbind" "systemd" ];
    group = lib.mkForce [ "files [SUCCESS=return]" "winbind [success=merge]" "systemd" ];
  };
  security.krb5 = lib.mkIf (ad != null) {
    enable = true;
    settings.libdefaults = {
      default_realm = ad.realm;
      dns_lookup_realm = false;
      dns_lookup_kdc = true;
    };
  };

  # Windows network discovery (WS-Discovery): the server shows up under
  # "Network" in Explorer, like Unraid does.
  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  # Name resolution for Windows: wsdd only announces the name, it doesn't
  # resolve it. mDNS answers the lookup for \\<hostName> (and <hostName>.local),
  # independent of the DNS server the PC uses.
  services.avahi = {
    enable = true;
    openFirewall = true;
    allowInterfaces = [ "br0" ];
    publish = {
      enable = true;
      addresses = true;
    };
  };

  # Don't start Samba before /bulk is there
  systemd.services.samba-smbd = {
    after = [ bulkReady ];
    wants = [ bulkReady ];
    unitConfig = whenUnlocked;
  };

  systemd.services.samba-winbindd = lib.mkIf (ad != null) { unitConfig = whenUnlocked; };

  systemd.services.hs-sync-shares = {
    description = "Publish folders without a Samba share (hs share repair)";
    after = [ bulkReady "samba-smbd.service" ];
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    # on the snapraid layout also measure the shares, for the size column of the interface
    script = ''
      bash ${scripts}/sync-shares.sh
      bash ${scripts}/manage-shares.sh --measure >/dev/null
    '';
    startAt = "03:35";
    onFailure = notifyFailure;
  };

  # TEMPORARY (2026-10-06): `ssh hs` sometimes paused 5-10 s between "Offering public key" and
  # "Server accepts key" after idle gaps (user/group lookups through winbind, or DNS). Every minute
  # the same lookups sshd does, so nothing goes cold; one that takes over 1 s is logged with the tag
  # hs-nss-warm (journalctl -t hs-nss-warm). Remove once the cause is known.
  systemd.services.hs-nss-warm = {
    description = "Keep winbind and DNS lookups warm for SSH logins (temporary)";
    path = [ "/run/current-system/sw" ];
    serviceConfig.Type = "oneshot";
    script = ''
      for cmd in 'getent initgroups adminuser' 'getent group "domain admins"' 'getent hosts ad.home.lan'; do
        s=$(date +%s%N)
        eval "$cmd" >/dev/null 2>&1 || true
        ms=$(( ($(date +%s%N) - s) / 1000000 ))
        [ "$ms" -gt 1000 ] && echo "slow: $cmd took $ms ms" | systemd-cat -t hs-nss-warm -p warning
      done
      exit 0
    '';
    startAt = "minutely";
  };
}
