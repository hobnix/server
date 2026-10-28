# network

The connection to the router that gives instances a FIXED address (a DHCP reservation). Variant: `unifi` (`hs net setup` stores the
router address and an API key; `scripts/unifi.sh` does the work). The runtime setting `networkProvider` names the variant and switches the
capability on (no rebuild); `hs net setup` sets it, `hs config migrate-settings` sets it for a server that already has /var/lib/hs/unifi.

- **Contract** (`scripts/providers/network/<variant>.sh`): `info` (variant, title), `ready` (exit 0 connected, 3 vault locked, 1 not
  connected), `used <ip>`, `reserved <mac>`, `set-ip <mac> <ip> [name]`. `fixed_address` in scripts/recipes/_lib.sh only talks to it.
- **Without a provider** nothing breaks: the recipe says the address is not fixed and asks the person to reserve it on the router.
  The `hs net` commands are left out of `hs help` (capability `network`; `hs help --all` shows them).
- A second variant (another router, a DHCP server on this host) is a new file in scripts/providers/network/ and its name in `choices`.

## Rules for working on it

Moved from CLAUDE.md (step 8 of docs/PLAN-modular-core.md); these are the rules for working on this part.

**The router connection is the capability `network`** (6a): runtime setting `networkProvider` (`unifi`; `hs net setup` sets it, `hs config migrate-settings` sets it for a server that has /var/lib/hs/unifi); a variant is scripts/providers/network/<variant>.sh (`info|ready|used|reserved|set-ip`) and `fixed_address` talks only to it (scripts/lib/network.sh); without one the recipe warns that the address is not fixed (capabilities/network/NOTES.md).
