# ad

A Samba Active Directory the server belongs to (`adDomain = { realm = "...", workgroup = "..." }` in machine.toml; the domain controller is
the `domain` recipe). On: Samba joins the domain, share logins are domain users, Domain Admins sign in to the web interface.
Off (no `adDomain`): standalone Samba, only the local adminuser signs in, and the commands that only make sense with a domain are left out
of `hs help` (`hs help --all` shows them): `hs user ...`, `hs dns ...`, `hs dc cert ...`; the web Identity pages are hidden.

The capability counts as on exactly when `adDomain` is set (computed in configuration.nix, written to /etc/hs/capabilities). Local users
instead of a domain are a later step (an `identity` provider with a `local` variant).

## Rules for working on it

Moved from CLAUDE.md (step 8 of docs/PLAN-modular-core.md); these are the rules for working on this part.

**Active Directory is the capability `ad`** (6b): on exactly when machine.toml has `adDomain` (computed in configuration.nix); off, Samba is standalone, `hs user|dns|dc cert` are tagged `capability:ad` and the web Identity pages are hidden (capabilities/ad/NOTES.md).
