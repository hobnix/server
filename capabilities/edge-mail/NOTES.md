# edge-mail

The public mail entry of a domain (the MX), ported from the proxyserver repo (modules/mail.nix). Postfix with a retry queue relays to the mail
server (Stalwart) over Tailscale, SPF of incoming mail is checked here (policyd-spf: the mail server only sees this node as the client), and the
certificate of the MX name comes from Let's Encrypt over port 80. Options: `edgeDomain`, `edgeMxHost`, `edgeAcmeEmail`, `edgeStalwartIp`.

- Mail addresses are not listed here: Postfix asks the mail server (`reject_unverified_recipient`, 550 for unknown addresses). The mail server must
  answer 550 for an unknown recipient at RCPT time, or this node would accept everything. Its hostname must NOT be the MX name ("mail loops back to myself").
- Outgoing mail does not go through this node: the mail server routes everything non-local through the SMTP2GO relay.
- Ports: 25 and 80 are open on the public side (NixOS firewall), nothing else of this part. The A record of `edgeMxHost` must exist before the first
  rebuild, and the reverse DNS (PTR) of the VPS must match it (Hetzner console).
- The DNS/MX records are outside this repo and are changed by hand, by checklist. A rehearsal beside the old
  VPS needs no DNS change at all.
- Facts for the status document and the health check come from /etc/hs/edge-mail.json (written by module.nix; no secrets).
- Not run on a real VPS yet. Evaluated with `bash scripts/dev/nix-matrix.sh`.
