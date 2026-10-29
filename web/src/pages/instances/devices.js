// Hardware passthrough: the shapes of `sys ct hardware` and `sys ct devices <ct>` (scripts/ct-device.sh) and the reason texts.
// An empty field is `-` on the wire; here it is ''.
const f = (v) => (v === undefined || v === '-' ? '' : v);

// the closed set of reason words in the header of scripts/ct-device.sh, as English texts
export const reasonText = {
  'host-disk': "the server's disks hang on it (the system disk, a pool or the backup disk)",
  'host-network': 'it is a network card of the server',
  'boot-display': "it is the server's screen (the console would go dark)",
  'host-system': 'it is a part of the server itself (a bridge, a hub or a board controller)',
  'nvidia-host': "the server's NVIDIA driver and the containers use this card",
  'no-iommu': 'IOMMU is off, so no PCI device can go into a VM. Switch on VT-d (Intel) or AMD-Vi/IOMMU (AMD) in the firmware setup',
  'group-shared': 'its IOMMU group also holds another device; the board does not separate them',
  'nvidia-recipe': 'the NVIDIA card goes into a container through a recipe that sets up its libraries (jellyfin, immich, tdarr)',
  'no-driver': 'the server has no driver for it, so a container cannot use it',
  'vm-only': 'only a VM can take a PCI device',
};

// hardware: kind, id, vendor:product, vendor, product, driver, iommu group, vm, ct, used by, count
export const hwOf = (r) => ({ kind: f(r[0]), id: f(r[1]), vidpid: f(r[2]), vendor: f(r[3]), product: f(r[4]), driver: f(r[5]), iommu: f(r[6]), vm: f(r[7]), ct: f(r[8]), usedBy: f(r[9]), count: f(r[10]) });

// devices of one instance: name, kind, id, plugged in, product, from (instance|profile), main device of a sibling
export const devOf = (r) => ({ name: f(r[0]), kind: f(r[1]), id: f(r[2]), present: r[3] === 'yes', product: f(r[4]), from: f(r[5]), with: f(r[6]) });

// can this device go into a VM (isVm) or a container? The vm / ct field says `ok` or one reason word.
export const canPass = (h, isVm) => {
  const w = isVm ? h.vm : h.ct;
  if (w === 'ok') return { ok: true, why: '' };
  return { ok: false, why: reasonText[w] || w || 'not possible' };
};

// the plugged-in USB devices for a recipe question of type usb (one per vendor:product, from `sys ct hardware` rows): value, label
export const usbOptions = (hwRows) => hwRows.map(hwOf)
  .filter((h) => h.kind === 'usb' && /^[0-9a-f]{4}:[0-9a-f]{4}$/.test(h.id))
  .map((h) => ({ value: h.id, label: `${h.product || h.vendor || h.id} (${h.id})${h.usedBy ? ` - in ${h.usedBy}` : ''}` }));

export const usbIdOk = (v) => /^[0-9a-f]{4}:[0-9a-f]{4}$/.test(v);
