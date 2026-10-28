# incus

Incus with its preseed (storage pool `default` on `fast/incus`, one profile per VLAN with the nightly snapshot), the option `incusUi`, the
nightly `hs-mac` job and the `incus-admin` group of adminuser. Needs the pool, so it requires `storage`.

- The VLAN bridges and tagged interfaces stay in configuration.nix (networking, only for `role = "homeserver"`).
- While encrypted storage is locked incus stays down (`systemd.services.incus.unitConfig = whenUnlocked`).
