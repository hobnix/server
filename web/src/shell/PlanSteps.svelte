<script>
  // The lines of a plan (step, note, warn, danger, section, text and the closing `long` line), as the plan dialog and the create dialog show them.
  // A step is marked + (something is added or started), ~ (something is changed) or - (something is removed or erased); the backend only says "step",
  // so the mark is read from the first word of the line (remove, delete, erase, wipe, destroy, purge, drop, forget, unmount -> -; change, set, rename,
  // move, update, replace, convert, restart, switch, resize -> ~; anything else +). Notes, warnings and dangers get their own mark.
  import { effectOf } from './effect.js';
  let { steps = [], long = false, dim = false } = $props();
  const effect = $derived(effectOf(steps));   // the sentence of ADR 0002 rule 4: shown first, before anything the person can apply

  const MINUS = /^(remove|delete|erase|wipe|destroy|purge|drop|forget|unmount|detach|stop|close|revoke)\b/i;
  const TILDE = /^(change|set|rename|move|update|replace|convert|restart|switch|resize|repair|rewrite|reset|apply|sync|reload|pause|resume)\b/i;
  const mark = (kind, text) => {
    if (kind === 'step') return MINUS.test(text) ? ['−', 'm'] : TILDE.test(text) ? ['~', 't'] : ['+', 'p'];
    if (kind === 'note') return ['i', 'n'];
    if (kind === 'long') return ['…', 'n'];
    if (kind === 'warn') return ['!', 'w'];
    if (kind === 'danger') return ['!', 'm'];
    return null;
  };
  const all = $derived([...steps.filter((_, i) => i !== effect?.index), ...(long ? [['long', 'This can take a while. It keeps running if you close the page.']] : [])]);
</script>

<div class="steps" style:opacity={dim ? 0.6 : 1}>
  {#if effect}
    <div class="effect {effect.kind}" data-effect={effect.kind}><i class="ph {effect.kind === 'now' ? 'ph-lightning' : 'ph-hammer'}"></i><span>{effect.text}</span></div>
  {/if}
  {#each all as s}
    {#if s[0] === 'section'}
      <div class="sect">{s[1]}</div>
    {:else if s[0] === 'text'}
      <div class="txt">{s[1]}</div>
    {:else if mark(s[0], s[1])}
      {@const m = mark(s[0], s[1])}
      <div class="step">
        <span class="mk {m[1]}">{m[0]}</span>
        <div class="h">{s[1]}</div>
      </div>
    {/if}
  {/each}
</div>

<style>
  .steps { display: flex; flex-direction: column; }
  .step { display: flex; gap: 12px; padding: 9px 0; border-bottom: 1px solid var(--line); }
  .mk { flex: none; width: 22px; height: 22px; display: grid; place-items: center; border: 1px solid var(--line-2); border-radius: var(--r); font: 600 13px var(--mono); color: var(--accent-ink); background: var(--panel-2); }
  .mk.p { color: var(--ok-ink); }
  .mk.m { color: var(--bad-ink); }
  .mk.w { color: var(--warn-ink); }
  .mk.n { color: var(--fg-3); }
  .h { font-size: 13px; padding-top: 2px; min-width: 0; overflow-wrap: anywhere; }
  .effect { display: flex; gap: 10px; align-items: flex-start; padding: 9px 12px; margin: 6px 0 4px; border: 1px solid var(--line-2); background: var(--panel-2); font-size: 13px; }
  .effect.now { color: var(--ok-ink); }
  .effect.rebuild { color: var(--warn-ink); }
  .effect span { color: var(--fg); }
  .sect { font: 500 11px var(--mono); text-transform: uppercase; letter-spacing: 0.08em; color: var(--fg-3); padding: 12px 0 2px; }
  .txt { font: 11.5px var(--mono); color: var(--fg-2); padding: 1px 0 1px 34px; word-break: break-word; }
</style>
