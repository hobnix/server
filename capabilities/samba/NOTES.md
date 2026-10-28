# samba

Samba (the shares `shares` and `sensitive`, the registry shares of `hs share add`), Active Directory membership when `adDomain` is set (nss,
krb5, winbind), WS-Discovery (wsdd), Avahi (the mDNS name Windows resolves) and the nightly `hs-sync-shares`. Needs the pools, so it requires `storage`.

- The capability `ad` only tags options; the AD wiring lives here because it is part of the Samba configuration.
- `hs-nss-warm` (temporary since 2026-10-06) lives here: it keeps winbind lookups warm for SSH logins.
