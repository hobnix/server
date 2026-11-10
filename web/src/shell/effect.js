// When a change takes effect (docs/adr/0002-system-state-vs-runtime-state.md rule 4). The plan of every change that touches configuration carries ONE
// note with a fixed sentence (scripts/lib/effect.sh): "takes effect at once" (runtime state) or "takes effect with hs rebuild" (declarative state,
// followed by the last measured rebuild time). The plan dialogs show it above the steps, before the Apply button. Pure functions, no Svelte.

export const EFFECT_NOW = /takes effect at once/i;
export const EFFECT_REBUILD = /takes effect with hs rebuild/i;

// the effect of a plan: { kind: 'now' | 'rebuild', text, index } from its first matching note, or null (a plan that changes no configuration)
export function effectOf(steps) {
  const list = steps || [];
  for (let i = 0; i < list.length; i++) {
    const [kind, text] = list[i];
    if (kind !== 'note') continue;
    if (EFFECT_REBUILD.test(text)) return { kind: 'rebuild', text, index: i };
    if (EFFECT_NOW.test(text)) return { kind: 'now', text, index: i };
  }
  return null;
}

// a saved change that waits for a rebuild gets the "Rebuild now" offer; a plan that starts the rebuild itself (area system, a job) does not
export const offersRebuild = (steps) => effectOf(steps)?.kind === 'rebuild';
