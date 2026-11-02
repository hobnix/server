<script>
  import { tip } from './tooltip.svelte.js';
  // The button. It knows when it is working: a spinner takes the place of the icon, the label may change (`busyLabel`), the width stays
  // and clicks are ignored (aria-busy, not `disabled`, so the tooltip and the keyboard focus stay).
  //   <Button variant="primary" icon="plus" onclick={add}>Add</Button>
  //   <Button icon="check-circle" busy={jobRunning('routes', ['apply'])} busyLabel="Applying…" onclick={...}>Apply</Button>
  // `busy` is for work the page follows itself (a running job); when onclick returns a promise the button is busy until it settles, so a
  // handler that awaits needs no flag of its own. `tooltip` is the text on hover; a disabled button shows its reason there.
  //   variant: primary | secondary (default) | ghost | danger     size: '' | sm     icon: a Phosphor name without `ph-`, or ''
  let { variant = 'secondary', size = '', icon = '', busy = false, busyLabel = '', disabled = false, tooltip = '', type = 'button', block = false,
        onclick = null, children, ...rest } = $props();

  let pending = $state(false);
  const working = $derived(busy || pending);

  async function click(e) {
    if (working || disabled || !onclick) return;
    const r = onclick(e);
    if (r && typeof r.then === 'function') {
      pending = true;
      try { await r; } finally { pending = false; }
    }
  }
</script>

<button {...rest} {type} class="btn btn-{variant} {size}" class:btn-block={block} class:busy={working} {disabled} aria-busy={working || undefined}
        aria-disabled={working || undefined} use:tip={tooltip} onclick={click}>
  {#if working}<i class="ph ph-circle-notch spin" aria-hidden="true"></i>{:else if icon}<i class="ph ph-{icon}" aria-hidden="true"></i>{/if}
  {#if working && busyLabel}{busyLabel}{:else}{@render children?.()}{/if}
</button>

<style>
  /* a working button keeps its colours (it is not "disabled"), only the pointer says it will not react */
  .busy { cursor: progress; }
</style>
