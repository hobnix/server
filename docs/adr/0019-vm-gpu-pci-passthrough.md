# 0019: VM hardware step: detect first, pass through second, bridge by default

Status: Proposed
Issue: hobnix/server#260 (research). Written without a machine that has a second GPU or an enabled IOMMU: every statement about real behaviour
is from the Incus documentation or general Linux knowledge and is marked **Unverified** where it matters. Not tested on hardware.

## Context

- The VM wizard (#258) asks for name, size and storage only. A VM that should run Windows with a graphics card, a TV tuner or a USB/SATA
  controller needs host devices; a VM on the home network needs a NIC that is not behind NAT.
- Incus VM devices (documentation, linuxcontainers.org/incus/docs/main/reference):
  - `gpu` type `physical`: containers and VMs; `pci`, `vendorid`, `productid`, `id`; no hotplug for VMs. A VM gets the whole card.
  - `gpu` type `mdev`: VMs only; needs a vGPU profile from `incus info --resources` (Intel GVT-g, NVIDIA vGPU with a licence). `sriov`: VMs
    only, a virtual function of an SR-IOV capable GPU. `mig`: containers only, so out of scope for a VM wizard.
  - `pci`: VMs only, `address` (required), `firmware` (option ROM, default true). For single devices such as capture or sound cards; the
    docs say a GPU or NIC should use `gpu` / `nic`. No hotplug.
  - `nic`: `bridged` (existing host bridge; host and guest can talk; MAC filtering), `macvlan` (on a host NIC; the host cannot reach the
    guest, no I/O limits, no bridge needed), `routed` (static routes, proxy ARP/NDP), `ovn` (needs an OVN network and chassis), `sriov`, `physical`
    (the NIC disappears from the host).
- Passthrough needs the IOMMU (VT-d / AMD-Vi enabled in firmware and, on Intel, `intel_iommu=on`), the device in an IOMMU group the VM can own
  as a whole, and the device bound to `vfio-pci`. **Unverified here:** that Incus binds `vfio-pci` itself at VM start and gives the original
  driver back at stop. That is the documented intent for `gpu`/`pci`, but a card the host console or a container (NVIDIA CDI,
  scripts/recipes/_lib.sh `nvidia_gpu`) is using cannot be taken, and a reset-bug card (many AMD/NVIDIA consumer cards) may not come back
  until the host reboots.
- Today the repo only has the container side: `nvidia.runtime` in scripts/recipes/_lib.sh. Nothing reads IOMMU groups.

## Decision

1. **Detection is read only and separate from the wizard.** A new system command `hs sys vm-hardware` (read; not built by this record)
   prints, as `key TAB value` lines like `hs sys hardware`: `iommu` (`on|off|unknown`), one `group` row per PCI device
   (group, address, class, vendor:device, driver, boot-vga), and `finding` rows (level, code, address, text). Codes: `iommu-off`,
   `iommu-cmdline`, `boot-gpu`, `shared-group`, `host-driver`. The parsing lives in scripts/lib/iommu.py (implemented with this record,
   tested against /sys fixtures). A console twin `hs vm hardware` prints the same through ui.sh. Shape additions follow the empty-field `-` rule.
2. **The wizard step is optional and collapsed by default.** "Hardware" lists only what can really be passed to a VM: GPUs (class 03xx)
   and other endpoints (not bridges, not the host bridge), each with its group. Network defaults to the host bridge the installer made
   (`bridged`); `macvlan` is offered as advanced with the warning that the host cannot reach the VM through it; OVN and `routed` are not offered.
3. **Warnings are the product.** The step blocks (cannot continue) on `iommu-off` and on a device in a group with a non-bridge device the
   user did not also select. It warns, and asks the user to type the device address, on `boot-gpu` (console is lost; a headless
   server may still want it) and `host-driver` (another consumer must be stopped). It never changes kernel parameters itself.
4. **Making the host ready is a NixOS change the user applies, shown as a plan.** The step prints the needed config and does not write it:
   `boot.kernelParams = [ "intel_iommu=on" "iommu=pt" ];` (Intel; AMD needs nothing but `iommu=pt` is common), and only for a card the host must
   never touch: `boot.initrd.kernelModules = [ "vfio_pci" "vfio" "vfio_iommu_type1" ];` plus `boot.extraModprobeConfig = "options vfio-pci
   ids=<vendor:device>,...";`. Whether this goes through `hs config` keys or `machine.toml` is an owner decision (open point 1).
5. **The VM gets the device with `incus config device add <vm> <name> gpu|pci ...`** by PCI address (not vendor/product, which matches several
   identical cards), as a job with a plan, inside the existing create flow (`manage-ct.sh --create`). It is added while the VM is stopped.
6. **A GPU in a group with other endpoints is never split** (no ACS override patch, no `pcie_acs_override`): that weakens isolation between
   devices and is not something a home-server wizard should switch on.
7. **mdev and SR-IOV are listed read-only** when `incus info --resources` reports a profile or VFs, with no wizard path until someone with such a card tests it.

## Failure modes the step must name in plain words

- IOMMU off: the VM fails to start (`vfio` cannot open the group). Detected before creating.
- Shared group: Incus/QEMU refuses the whole group, or the host loses a SATA/USB controller that sits in the same group (host disks vanish).
  Detected; the wizard shows what else is in the group, including its driver, so a controller holding the data disks is called out.
- Boot GPU: host console black; some firmwares re-POST and cannot hand the card back. **Unverified.**
- Reset bug: VM stop leaves the card unusable until reboot. Cannot be detected; documented as a risk, not a finding.
- NVIDIA driver on the host loaded: the proprietary driver holds the card; `nvidia.runtime` containers need it. A card cannot be shared between
  a container (CDI) and a VM at once; the step says which one holds it.
- Windows guests: code 43 / missing drivers, ROM issues (`firmware`), resizable BAR (`rebar.<N>.size` exists in Incus). Out of the
  wizard; docs only.
- macvlan: host cannot reach the VM and the VM cannot reach the host; Wi-Fi uplinks cannot be bridged or macvlan'd at all in most setups.

## Consequences

- Detection can be built and tested without hardware (fixtures); the passthrough path itself cannot, and the first user with a spare card is
  the real test. The wizard text and docs must say "Not tested on hardware yet." until then.
- A server with one GPU gets a warning and a clear way out, not a half-started VM.
- Follow-ups: `hs sys vm-hardware` + registry/openapi rows + smoke probe; wizard step; NixOS plan output; a guide in docs/.

## Open points

1. Who writes the NixOS kernel parameters and vfio ids: a `machine.toml` key (rebuild, user-reviewed) or only printed text? Recommendation: printed first.
2. Is a headless boot GPU passthrough acceptable (console lost) or blocked outright? Recommendation: allow after typed confirmation.
3. NIC default: the installer's bridge exists already? To check before the step offers `bridged`.
4. Should a stopped VM with a GPU block `hs update`/reboot flows (a reset-bug card)? No data.
5. vGPU/mdev licensing (NVIDIA) is out of scope; Intel GVT-g is deprecated upstream for newer CPUs. **Unverified**.
