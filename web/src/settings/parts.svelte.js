// The parts of `hs sys parts list` (name, on|off, extension|part, nix, switch, title), shared by the Capabilities overview and a capability page.
// A switch opens the plan first; a part with a NixOS module takes effect at the next rebuild, an extension without one at once.
import { poll, rows } from '../data.svelte.js';
import { openPlan } from '../ui.svelte.js';

// call once from a component's script; `parts()` is the current list
export function useParts() {
  const partList = poll('/api/sys/parts/list', 15000);
  const parts = () => rows(partList).map((r) => ({ name: r[0], on: r[1] === 'on', kind: r[2], nix: r[3] === 'yes', canSwitch: r[4] === 'yes', title: r[5] }));
  return { partList, parts };
}
export const flip = (p) => openPlan('parts', [p.on ? 'disable' : 'enable', p.name], `${p.on ? 'Switch off' : 'Switch on'} ${p.name}`);
