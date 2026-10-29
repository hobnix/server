// The tiles of the dashboard (web/src/dashboard/board.js): group order, tile order, icon fallback, the Incus tile.
import { groupTiles, iconFor, incusTile, monogram } from '../web/src/dashboard/board.js';

let ok = 0, bad = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log(`  ok    ${name}`); } else { bad++; console.log(`  FAIL  ${name} ${extra}`); } };

console.log('-- groups');
const tiles = [
  { title: 'Zed', group: 'Zoo' }, { title: 'b', group: 'Media' }, { title: 'Grafana', group: 'Monitoring' }, { title: 'Incus', group: 'Administration' },
  { title: 'Alpha', group: 'Alpha' }, { title: 'Jellyfin', group: 'Media' }, { title: 'x', group: 'Other' }, { title: 'App', group: 'Apps' },
  { title: 'Tool', group: 'Tools' }, { title: 'Game', group: 'Games' }, { title: 'A', group: 'Media' },
];
const g = groupTiles(tiles);
check('known groups in order, unknown alphabetically after', g.map((x) => x.group).join(',') === 'Administration,Apps,Media,Monitoring,Games,Tools,Other,Alpha,Zoo', g.map((x) => x.group).join(','));
check('tiles sorted by title within a group', g.find((x) => x.group === 'Media').tiles.map((t) => t.title).join(',') === 'A,b,Jellyfin');
check('a tile without group goes to Other', groupTiles([{ title: 'q' }])[0].group === 'Other');
check('no tiles, no groups', groupTiles([]).length === 0 && groupTiles(undefined).length === 0);
check('the input is not changed', tiles[0].title === 'Zed' && tiles.length === 11);

console.log('-- icons');
check('a known icon maps to Phosphor', iconFor('jellyfin') === 'film-strip');
check('an mdi icon maps', iconFor('mdi-email-lock') === 'envelope-open');
check('an unknown icon is null', iconFor('nonsense') === null && iconFor('') === null && iconFor(undefined) === null);
check('inherited object keys are not icons', iconFor('constructor') === null && iconFor('toString') === null);
check('monogram is the first letter, upper case', monogram('radarr') === 'R' && monogram('') === '?');

console.log('-- Incus');
const i = incusTile('nas.local');
check('the Incus tile', i.group === 'Administration' && i.title === 'Incus' && i.icon === 'cube' && i.description === 'Containers and VMs');
check('its link uses the host name of the page', i.href === 'https://nas.local:8443/ui/');

console.log(`  -> ${ok} ok, ${bad} failed`);
process.exit(bad ? 1 : 0);
