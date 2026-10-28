# The capability "edge-mail" (capabilities/edge-mail/NOTES.md): this node is the public MX of one mail domain. Ported from the proxyserver repo (modules/mail.nix):
# Postfix accepts mail for the domain, checks SPF at the door, asks the mail server behind it (over Tailscale) whether the recipient exists, relays to it
# and keeps a retry queue while it is down. The certificate of the MX name comes from Let's Encrypt over port 80.
{ config, lib, pkgs, hs, ... }:

let
  m = hs.machine;
  domain = m.edgeDomain;
  mxHost = m.edgeMxHost;
  stalwartIp = m.edgeStalwartIp;
  configured = domain != "" && mxHost != "" && stalwartIp != "" && m.edgeAcmeEmail != "";
  certDir = config.security.acme.certs.${mxHost}.directory;
in
{
  warnings = lib.optional (!configured) "capability edge-mail is on, but edgeDomain, edgeMxHost, edgeAcmeEmail or edgeStalwartIp is empty in machine.toml: no mail is accepted";

  # what scripts/lib/edge_facts.py (status document, health check) reads; no secrets
  environment.etc."hs/edge-mail.json".text = builtins.toJSON {
    inherit domain mxHost stalwartIp;
    acmeEmail = m.edgeAcmeEmail;
    certFile = if configured then "${certDir}/fullchain.pem" else "";
  };

  # port 25 (mail) and 80 (the certificate check) are the only ports of this part that are open on the public side
  networking.firewall.allowedTCPPorts = lib.mkIf configured [ 25 80 ];

  # Certificate for the mail name, checked over port 80. The A record of the MX name must exist before the first rebuild.
  security.acme = lib.mkIf configured {
    acceptTerms = true;
    defaults.email = m.edgeAcmeEmail;
    certs.${mxHost} = {
      listenHTTP = ":80";
      group = "postfix";
      reloadServices = [ "postfix.service" ];
    };
  };

  services.postfix = lib.mkIf configured {
    enable = true;

    # Everything for the domain goes to the mail server over Tailscale. While it does not answer (restart, update) the mail waits here.
    transport = "${domain}    smtp:[${stalwartIp}]:25\n";

    settings.main = {
      myhostname = mxHost;
      mydestination = "";
      mynetworks_style = "host";
      relay_domains = [ domain ];

      smtpd_tls_security_level = "may";
      smtpd_tls_cert_file = "${certDir}/fullchain.pem";
      smtpd_tls_key_file = "${certDir}/key.pem";
      # the mail server's own certificate is self-signed at first: inside the tailnet any is fine
      smtp_tls_security_level = "may";

      # SPF is checked here, against the real sender address: the mail server only sees this node's Tailscale address as the client.
      smtpd_recipient_restrictions = [
        "check_policy_service unix:private/policyd-spf"
        "reject_unverified_recipient"
      ];
      "policyd-spf_time_limit" = "3600s";

      # Which addresses exist is not kept here: an unknown recipient is checked by asking the mail server (a probe that stops after RCPT, nothing
      # is sent). Unknown addresses are refused at the door, so no bounce goes to a forged sender. The server must answer 550 for an unknown
      # address at RCPT time, or this node would accept everything. A new address works after at most 5 minutes (negative cache); a known one
      # stays accepted while the server is down (positive cache), so its mail still waits in the queue. A deleted address is dropped within an hour.
      unverified_recipient_reject_code = "550";
      address_verify_negative_expire_time = "5m";
      address_verify_negative_refresh_time = "1m";
      address_verify_positive_expire_time = "7d";
      address_verify_positive_refresh_time = "1h";

      # the safety net: retry every 1 to 15 minutes, up to 5 days
      queue_run_delay = "60s";
      minimal_backoff_time = "60s";
      maximal_backoff_time = "15m";
      maximal_queue_lifetime = "5d";
    };

    # The SPF policy service Postfix asks (smtpd_recipient_restrictions above): it rejects mail whose sender domain says "not from this IP" (Fail)
    # and adds a Received-SPF header; no SPF record, softfail and neutral pass.
    settings.master."policyd-spf" = {
      type = "unix";
      privileged = true;   # spawn(8) must run privileged to drop to "nobody"
      chroot = false;
      maxproc = 0;
      command = "spawn";
      args = [ "user=nobody" "argv=${pkgs.spf-engine}/bin/policyd-spf" ];
    };
  };

  environment.etc."python-policyd-spf/policyd-spf.conf" = lib.mkIf configured {
    text = ''
      # TestOnly = 1 really rejects, 0 only logs (the name is misleading)
      debugLevel = 1
      TestOnly = 1
      HELO_reject = Fail
      Mail_From_reject = Fail
      PermError_reject = False
      TempError_Defer = False
      skip_addresses = 127.0.0.0/8,::ffff:127.0.0.0/104,::1
    '';
  };

  # Start only once the certificate exists; a failure is a push message at once (the health check finds the rest within 15 minutes).
  systemd.services.postfix = lib.mkIf configured {
    wants = [ "acme-finished-${mxHost}.target" ];
    after = [ "acme-finished-${mxHost}.target" ];
    unitConfig.OnFailure = hs.notifyFailure;
  };
}
