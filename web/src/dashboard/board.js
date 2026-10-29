// The pure part of the dashboard (tested with node, tests/web-board.mjs): grouping, ordering and icons of the tiles.
import { icons } from './icons.js';

export const GROUP_ORDER = ['Administration', 'Apps', 'Media', 'Monitoring', 'Games', 'Tools', 'Other'];

const byText = (a, b) => String(a).localeCompare(String(b), undefined, { sensitivity: 'base', numeric: true });

// tiles -> [{group, tiles}]: known groups in GROUP_ORDER, unknown groups alphabetically after them, tiles by title inside a group
export function groupTiles(tiles) {
  const by = new Map();
  for (const t of tiles ?? []) {
    const g = t.group || 'Other';
    if (!by.has(g)) by.set(g, []);
    by.get(g).push(t);
  }
  const rank = (g) => { const i = GROUP_ORDER.indexOf(g); return i < 0 ? GROUP_ORDER.length : i; };
  return [...by.keys()]
    .sort((a, b) => rank(a) - rank(b) || byText(a, b))
    .map((group) => ({ group, tiles: by.get(group).slice().sort((a, b) => byText(a.title, b.title)) }));
}

// descriptor icon -> Phosphor name, or null (the tile then shows a monogram)
export const iconFor = (name) => (name && Object.hasOwn(icons, name) ? icons[name] : null);

// the Incus tile is drawn by the page itself: no host address comes from the server
export const incusTile = (host) => ({
  service: 'incus', group: 'Administration', title: 'Incus', href: `https://${host}:8443/ui/`,
  description: 'Containers and VMs', icon: 'cube', stats: [],
});

export const monogram = (title) => (String(title ?? '').trim()[0] ?? '?').toUpperCase();
