<script>
  import { tip } from './tooltip.svelte.js';
  // Switch (outline track, small square thumb) and, with `box`, the checkbox (button with a check). A disabled cell shows its REASON as the
  // tooltip and, with `showReason`, as small text next to it, so "why can't I?" never needs a click.
  //   <Switch bind:checked label="Backup" />   <Switch box checked disabled reason="Email cannot carry a heartbeat" />
  let { checked = $bindable(false), disabled = false, reason = '', label = '', box = false, onchange = null, showReason = false } = $props();

  function toggle() {
    if (disabled) return;
    checked = !checked;
    onchange?.(checked);
  }
</script>

<span class="sw">
  <button type="button" class={box ? 'cbx' : 'tog'} role={box ? 'checkbox' : 'switch'} aria-checked={checked} aria-label={label || undefined}
          aria-disabled={disabled || undefined} class:off={disabled} use:tip={disabled ? reason : ''} onclick={toggle}></button>
  {#if disabled && reason && showReason}<span class="why">{reason}</span>{/if}
</span>

<style>
  .sw { display: inline-flex; align-items: center; gap: 8px; vertical-align: middle; }
  button { padding: 0; margin: 0; position: relative; flex: none; cursor: pointer; }
  .tog { width: 32px; height: 16px; border: 1px solid var(--line-2); border-radius: var(--r); background: transparent; }
  .tog::after { content: ''; position: absolute; left: 2px; top: 2px; width: 10px; height: 10px; background: var(--fg-3); transition: transform 0.15s, background 0.15s; }
  .tog:hover { border-color: var(--fg-3); }
  .tog[aria-checked='true'] { background: color-mix(in oklch, var(--accent) 22%, transparent); border-color: color-mix(in oklch, var(--accent) 70%, var(--line-2)); }
  .tog[aria-checked='true']::after { transform: translateX(16px); background: var(--accent-ink); }
  .cbx { width: 18px; height: 18px; border: 1px solid var(--line-2); border-radius: var(--r); background: var(--panel-2); }
  .cbx[aria-checked='true'] { background: var(--accent); border-color: transparent; }
  .cbx[aria-checked='true']::after { content: ''; position: absolute; left: 5px; top: 1px; width: 5px; height: 10px; border: solid var(--on-accent); border-width: 0 2px 2px 0; transform: rotate(45deg); }
  .off { opacity: 0.35; cursor: not-allowed; }
  .why { color: var(--fg-3); font-size: 12px; }
</style>
