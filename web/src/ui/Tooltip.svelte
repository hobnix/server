<script>
  // The one tooltip element of the app (state and the `tip` action: ui/tooltip.svelte.js). Mounted once in App.svelte. It measures itself after it
  // renders, then placeTip (ui/tooltip-place.js) puts it on the preferred side of the trigger, flipped and clamped into the viewport.
  import { tipState as t, TIP_ID } from './tooltip.svelte.js';
  import { placeTip } from './tooltip-place.js';

  let el = $state(null);
  let pos = $state({ left: 0, top: 0, ready: false });

  $effect(() => {
    if (!t.open || !el) { pos = { left: 0, top: 0, ready: false }; return; }
    void t.text; void t.keys;   // a changed text is measured again
    const p = placeTip(t.rect, { w: el.offsetWidth, h: el.offsetHeight }, innerWidth, innerHeight, t.pref);
    pos = { left: p.left, top: p.top, ready: true };
  });
</script>

{#if t.open}
  <div id={TIP_ID} role="tooltip" class="tip" bind:this={el} style:left="{pos.left}px" style:top="{pos.top}px" style:visibility={pos.ready ? 'visible' : 'hidden'}>
    <span>{t.text}</span>{#if t.keys}<kbd>{t.keys}</kbd>{/if}
  </div>
{/if}

<style>
  .tip { position: fixed; z-index: 70; max-width: 260px; padding: 6px 9px; background: var(--panel-3); color: var(--fg); border: 1px solid var(--line-2); border-radius: var(--r);
         box-shadow: var(--shadow); font-size: 12px; line-height: 1.4; overflow-wrap: anywhere; pointer-events: none; animation: tipin 90ms ease-out; }
  kbd { margin-left: 8px; padding: 0 4px; border: 1px solid var(--line-2); font: 11px var(--mono); color: var(--fg-3); }
  @keyframes tipin { from { opacity: 0; } to { opacity: 1; } }
  @media (prefers-reduced-motion: reduce) { .tip { animation: none; } }
</style>
