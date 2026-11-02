# shellcheck shell=bash
# The physical network cards, read from /sys/class/net (test knob HS_SYS_NET: a fake folder). A card is physical when it has a `device` entry;
# bridges, VLANs, tunnels and loopback do not.
#   nic_net_dir          the folder to read
#   nic_exists <name>    there is an interface of that name
#   nic_physical <name>  it is a physical card
#   nic_list             the physical cards, one name per line, sorted
#   nic_link <name>      up (a cable is connected: carrier 1) or down
nic_net_dir() { printf '%s\n' "${HS_SYS_NET:-/sys/class/net}"; }
nic_exists() { [ -e "$(nic_net_dir)/$1" ]; }
nic_physical() { [ -e "$(nic_net_dir)/$1/device" ]; }
nic_list() {
  local d n
  for d in "$(nic_net_dir)"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    nic_physical "$n" && printf '%s\n' "$n"
  done | sort
}
nic_link() { if [ "$(cat "$(nic_net_dir)/$1/carrier" 2>/dev/null || true)" = 1 ]; then echo up; else echo down; fi; }
