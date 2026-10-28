<script>
  // A status is never colour alone: the 8 px dot always comes with a word. `state` is ok | warn | bad | info | off; `label` is the word (default:
  // the generic word of the state). `bare` hides the word visually (tree rows, where space is short) but keeps it for screen readers and as the tooltip.
  //   <StatusDot state="warn" label="3 problems" />   <StatusDot state="ok" bare label="online" />
  let { state = 'off', label = '', bare = false, large = false } = $props();
  const words = { ok: 'healthy', warn: 'warning', bad: 'failed', info: 'in progress', off: 'off' };
  const word = $derived(label || words[state] || state);
</script>

<span class="sd" title={bare ? word : undefined}>
  <span class="dot {state}" class:lg={large} aria-hidden="true"></span>
  {#if bare}<span class="sr">{word}</span>{:else}<span class="w">{word}</span>{/if}
</span>

<style>
  .sd { display: inline-flex; align-items: center; gap: 8px; white-space: nowrap; }
  @media (max-width: 860px) { .sd { white-space: normal; align-items: flex-start; } .sd .dot { margin-top: 4px; } }
  .lg { width: 10px; height: 10px; }
  .w { color: var(--fg-2); }
  .sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
</style>
