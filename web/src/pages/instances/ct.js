// Shared by the Instances, Apps, Services and Network pages: one reading of `sys ct list`, and the links between them.
import { go, url } from '../../route.svelte.js';
import { setSelection } from '../../select.svelte.js';

// ct list: name, type, state, address, ram, cpu, autostart, mac pinned, docker, disk, snapshots, last snapshot, memory in use, cpu time, bindings, last start
export const ctOf = (r) => ({ name: r[0], type: r[1], state: r[2], address: r[3], ram: r[4], cpu: r[5], autostart: r[6], docker: r[8], disk: r[9], lastSnap: r[11] });

export const isVm = (c) => /virtual|VM/i.test(c.type);
export const isRunning = (c) => /running/i.test(c.state);

// the IPv4 address in a cell such as "10.10.95.20 (eth0)"; '' when there is none
export const ipOf = (addr) => (/(\d+\.\d+\.\d+\.\d+)/.exec(addr || '') || [])[1] ?? '';

// the icons the design gives the known instances; anything else is a cube (a VM a tower)
export const ctIcons = { dc1: 'identification-badge', cloudflared: 'cloud', zoraxy: 'arrows-split', docker: 'shipping-container', homepage: 'house', jellyfin: 'film-strip', immich: 'images', stalwart: 'envelope-simple', 'pelican-panel': 'game-controller', 'pelican-wings': 'wind', monitoring: 'chart-line' };
export const ctIcon = (c) => ctIcons[c.name] ?? (isVm(c) ? 'desktop-tower' : 'cube');

// A link that opens another page of this node with an item preselected (kind = the select.svelte.js kind of that page). `href` makes it a real
// link (middle click, copy address); a plain click goes there with go() and the selection.
export function link(path, kind = '', name = '') {
  return {
    href: url(path),
    onclick: (e) => {
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.button) return;
      e.preventDefault();
      e.stopPropagation();
      if (kind && name) setSelection(kind, name);
      go(path);
    },
  };
}

// the services (services list rows: name, title, target, exposure, names, wants) whose target is this instance: its name or its address
export function servicesOf(c, services) {
  const ip = ipOf(c.address);
  return services.filter((s) => {
    const t = s.target || '';
    return t.split(/[^A-Za-z0-9.-]+/).some((w) => w === c.name || (ip && w === ip));
  });
}
