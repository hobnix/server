// The parts of `hs sys parts list` (name, on|off, extension|part, nix, switch, title), shared by the Capabilities overview and a capability page.
// A switch opens the plan first; a part with a NixOS module takes effect at the next rebuild, an extension without one at once.
import { poll, rows } from '../data.svelte.js';
import { openPlan } from '../ui.svelte.js';

// call once from a component's script; `parts()` is the current list
export function useParts() {
  const partList = poll('/api/sys/parts/list', 15000);
  const pendingList = poll('/api/sys/parts/pending', 15000);
  const pending = () => new Set(rows(pendingList).map((r) => r[0]));
  const parts = () => rows(partList).map((r) => ({ name: r[0], on: r[1] === 'on', kind: r[2], nix: r[3] === 'yes', canSwitch: r[4] === 'yes', title: r[5], pending: pending().has(r[0]) }));
  return { partList, parts };
}
// a part switched on in machine.toml but not built yet (`pending`) still reads off: it counts as on, so the button switches it off again
export const flip = (p) => { const want = p.on || p.pending; return openPlan('parts', [want ? 'disable' : 'enable', p.name], `${want ? 'Switch off' : 'Switch on'} ${p.name}`); };
